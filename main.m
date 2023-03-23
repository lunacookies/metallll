#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

#define kSampleCount 4
#define kMaxQuadCount 1024

struct FontAtlas {
	void* pixels;
	uint16_t width;
	uint16_t height;
	uint16_t* xPositions;
	uint16_t* advances;
	uint16_t spaceAdvance;
};

struct FontAtlas fontGlyph()
{
	CTFontRef font = (__bridge CTFontRef)
	        [NSFont systemFontOfSize:80
	                          weight:NSFontWeightBlack];

	uint16_t encoded[26] = { 0 };
	for (size_t i = 0; i < 26; i++)
		encoded[i] = 'a' + i;

	CGGlyph glyphs[26] = { 0 };
	CTFontGetGlyphsForCharacters(font, encoded, glyphs, 26);

	CGRect rects[26] = { 0 };
	CTFontGetOpticalBoundsForGlyphs(font, glyphs, rects, 26, 0);

	CGSize rawAdvances[26] = { 0 };
	CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault,
	        glyphs, rawAdvances, 26);

	uint16_t* advances = calloc(26, sizeof(uint16_t));
	for (size_t i = 0; i < 26; i++)
		advances[i] = ceil(rawAdvances[i].width) * 2;

	uint16_t height = fmax(CTFontGetAscent(font), CTFontGetCapHeight(font))
	        + CTFontGetDescent(font);

	CGPoint positions[26] = { 0 };
	uint16_t* xPositions = calloc(26, sizeof(uint16_t));
	uint16_t currentAdvance = 0;
	for (size_t i = 0; i < 26; i++) {
		xPositions[i] = currentAdvance * 2;
		positions[i] = (CGPoint) {
			currentAdvance,
			height - rects[i].origin.y - height,
		};
		currentAdvance += advances[i];
	}

	void* pixels = calloc(currentAdvance * 2 * height * 2, 1);
	CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceLinearGray);
	CGContextRef ctx = CGBitmapContextCreate(
	        pixels,
	        currentAdvance * 2, height * 2, 8, currentAdvance * 2,
	        colorspace, kCGImageAlphaOnly);
	CGContextScaleCTM(ctx, 2, 2);

	CTFontDrawGlyphs(font, glyphs, positions, 26, ctx);

	CGGlyph glyph = { 0 };
	uint16_t space = ' ';
	CGSize spaceAdvance = { 0 };
	CTFontGetGlyphsForCharacters(font, &space, &glyph, 1);
	CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault,
	        &glyph, &spaceAdvance, 1);

	return (struct FontAtlas) {
		.pixels = pixels,
		.width = currentAdvance * 2,
		.height = height * 2,
		.xPositions = xPositions,
		.advances = advances,
		.spaceAdvance = ceil(spaceAdvance.width) * 2,
	};
}

struct Uniforms {
	vector_float2 position;
	vector_float2 size;
	vector_ushort2 glyphTopLeft;
	vector_ushort2 glyphSize;
	vector_float4 color;
	bool isGlyph;
};

struct GeometryBuilder {
	struct Uniforms* ptr;
	size_t count;
};

struct GeometryBuilder GeometryBuilderCreate(id<MTLBuffer> uniformsBuffer)
{
	return (struct GeometryBuilder) {
		.ptr = uniformsBuffer.contents,
		.count = 0,
	};
}

void GeometryBuilderPush(struct GeometryBuilder* gb, struct Uniforms* uniforms)
{
	gb->ptr[gb->count] = *uniforms;
	gb->count++;
	assert(gb->count < kMaxQuadCount);
}

void GeometryBuilderPushRect(struct GeometryBuilder* gb, vector_float2 position, vector_float2 size, vector_float4 color)
{
	GeometryBuilderPush(gb,
	        &(struct Uniforms) {
	                .position = position,
	                .size = size,
	                .color = color,
	                .isGlyph = false,
	        });
}

void GeometryBuilderPushGlyph(struct GeometryBuilder* gb, const struct FontAtlas* atlas, uint8_t index, vector_float2 position, vector_float4 color)
{
	GeometryBuilderPush(gb,
	        &(struct Uniforms) {
	                .position = position,
	                .size = { atlas->advances[index], atlas->height },
	                .color = color,
	                .glyphTopLeft = { atlas->xPositions[index], 0 },
	                .glyphSize = { atlas->advances[index], atlas->height },
	                .isGlyph = true,
	        });
}

@interface MainView : NSView {
	CAMetalLayer* metalLayer;
	CVDisplayLinkRef displayLink;
	id<MTLDevice> device;
	id<MTLCommandQueue> commandQueue;
	id<MTLRenderPipelineState> renderPipeline;

	MTLTextureDescriptor* multisampleTextureDesc;
	id<MTLTexture> multisampleTexture;

	id<MTLBuffer> indexBuffer;
	id<MTLBuffer> uniformsBuffer;
	id<MTLTexture> texture;

	struct FontAtlas atlas;
}
@end

@implementation MainView

- (id)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	self.wantsLayer = YES;
	self.layer = [CAMetalLayer layer];
	metalLayer = (CAMetalLayer*)self.layer;
	device = MTLCreateSystemDefaultDevice();
	metalLayer.device = device;

	metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
	metalLayer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
	metalLayer.wantsExtendedDynamicRangeContent = YES;
	self.layer.opaque = NO;

	metalLayer.framebufferOnly = NO;

	multisampleTextureDesc = [[MTLTextureDescriptor alloc] init];
	multisampleTextureDesc.pixelFormat = metalLayer.pixelFormat;
	multisampleTextureDesc.textureType = MTLTextureType2DMultisample;
	multisampleTextureDesc.sampleCount = kSampleCount;

	uint16_t indexBufferData[6] = { 0, 1, 2, 0, 2, 3 };
	indexBuffer = [device newBufferWithBytes:indexBufferData
	                                  length:sizeof(indexBufferData)
	                                 options:MTLResourceCPUCacheModeDefaultCache];

	uniformsBuffer = [device newBufferWithLength:sizeof(struct Uniforms) * kMaxQuadCount
	                                     options:MTLResourceCPUCacheModeDefaultCache];

	NSError* error = nil;

	atlas = fontGlyph();
	MTLTextureDescriptor* textureDesc
	        = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatA8Unorm
	                                                             width:atlas.width
	                                                            height:atlas.height
	                                                         mipmapped:NO];
	texture = [device newTextureWithDescriptor:textureDesc];
	MTLRegion region = MTLRegionMake2D(0, 0, atlas.width, atlas.height);
	[texture replaceRegion:region
	           mipmapLevel:0
	             withBytes:atlas.pixels
	           bytesPerRow:atlas.width];

	NSURL* path = [NSURL fileURLWithPath:@"out/shaders.metallib" isDirectory:false];
	id<MTLLibrary> library =
	        [device newLibraryWithURL:path
	                            error:&error];
	if (error != nil) {
		NSLog(@"%@", error);
		exit(1);
	}

	MTLRenderPipelineDescriptor* desc =
	        [[MTLRenderPipelineDescriptor alloc] init];
	desc.rasterSampleCount = kSampleCount;

	MTLRenderPipelineColorAttachmentDescriptor* framebufferAttachment
	        = desc.colorAttachments[0];

	framebufferAttachment.pixelFormat = metalLayer.pixelFormat;

	framebufferAttachment.blendingEnabled = YES;
	framebufferAttachment.sourceRGBBlendFactor = MTLBlendFactorOne;
	framebufferAttachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
	framebufferAttachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	framebufferAttachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

	desc.vertexFunction = [library newFunctionWithName:@"vertexShader"];
	desc.fragmentFunction = [library newFunctionWithName:@"fragmentShader"];

	renderPipeline = [device newRenderPipelineStateWithDescriptor:desc
	                                                        error:&error];
	if (error != nil) {
		NSLog(@"%@", error);
		exit(1);
	}

	commandQueue = [device newCommandQueue];

	CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
	CVDisplayLinkSetOutputCallback(
	        displayLink, displayLinkCallback, (__bridge void*)self);
	CVDisplayLinkStart(displayLink);

	NSNotificationCenter* notificationCenter = [NSNotificationCenter defaultCenter];
	[notificationCenter addObserver:self
	                       selector:@selector(windowWillClose:)
	                           name:NSWindowWillCloseNotification
	                         object:self.window];

	return self;
}

- (void)windowWillClose:(NSNotification*)notification
{
	if (notification.object == self.window)
		CVDisplayLinkStop(displayLink);
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	[self updateDrawableSize];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self updateDrawableSize];
}

- (void)updateDrawableSize
{
	NSSize size = self.bounds.size;
	size.width *= self.window.screen.backingScaleFactor;
	size.height *= self.window.screen.backingScaleFactor;
	if (size.width == 0 && size.height == 0)
		return;
	metalLayer.drawableSize = size;

	[self updateMultisampleTexture:size];
}

- (void)updateMultisampleTexture:(NSSize)size
{
	multisampleTextureDesc.width = size.width;
	multisampleTextureDesc.height = size.height;
	multisampleTexture
	        = [device newTextureWithDescriptor:multisampleTextureDesc];
}

static CVReturn displayLinkCallback(
        CVDisplayLinkRef displayLink,
        const CVTimeStamp* now,
        const CVTimeStamp* outputTime,
        CVOptionFlags flagsIn,
        CVOptionFlags* flagsOut,
        void* displayLinkContext)
{
	MainView* view = (__bridge MainView*)displayLinkContext;
	[view renderOneFrame];
	return kCVReturnSuccess;
}

- (void)renderOneFrame
{
	id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
	id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

	MTLRenderPassDescriptor* passDesc = [[MTLRenderPassDescriptor alloc] init];
	passDesc.colorAttachments[0].texture = multisampleTexture;
	passDesc.colorAttachments[0].resolveTexture = drawable.texture;
	passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
	passDesc.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
	passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

	id<MTLRenderCommandEncoder> commandEncoder =
	        [commandBuffer renderCommandEncoderWithDescriptor:passDesc];
	[commandEncoder setRenderPipelineState:renderPipeline];

	float width = metalLayer.drawableSize.width;
	float height = metalLayer.drawableSize.height;
	float factor = 1;
	float padding = 100;

	struct GeometryBuilder gb = GeometryBuilderCreate(uniformsBuffer);

	GeometryBuilderPushRect(&gb,
	        simd_make_float2(0, 0),
	        simd_make_float2(width, height),
	        simd_make_float4(0.03, 0.03, 0.03, 0.95));

	char* s = "lorem ipsum\ndolor sit amet";
	float x = padding;
	float y = padding;
	for (; *s; s++) {
		if (*s == '\n') {
			x = padding;
			y += atlas.height;
			continue;
		}
		if (*s == ' ') {
			x += atlas.spaceAdvance;
			continue;
		}
		uint8_t index = *s - 'a';
		GeometryBuilderPushGlyph(&gb,
		        &atlas,
		        index,
		        simd_make_float2(x, y),
		        simd_make_float4(0.7, 0.7, 0.7, 1));
		x += atlas.advances[index];
	}

	[commandEncoder setVertexBuffer:uniformsBuffer
	                         offset:0
	                        atIndex:0];

	vector_uint2 viewportSize = { width, height };
	[commandEncoder setVertexBytes:&viewportSize
	                        length:sizeof(viewportSize)
	                       atIndex:1];

	vector_ushort2 atlasSize = { atlas.width, atlas.height };
	[commandEncoder setVertexBytes:&atlasSize
	                        length:sizeof(atlasSize)
	                       atIndex:2];

	float edrMax = self.window.screen.maximumExtendedDynamicRangeColorComponentValue;
	[commandEncoder setVertexBytes:&edrMax
	                        length:sizeof(edrMax)
	                       atIndex:3];

	[commandEncoder setFragmentTexture:texture
	                           atIndex:0];

	[commandEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
	                           indexCount:6
	                            indexType:MTLIndexTypeUInt16
	                          indexBuffer:indexBuffer
	                    indexBufferOffset:0
	                        instanceCount:gb.count];

	[commandEncoder endEncoding];

	[commandBuffer presentDrawable:drawable];
	[commandBuffer commit];
}

// We accept key events.
- (BOOL)acceptsFirstResponder
{
	return YES;
}

// Forward raw key events to relevant methods
// like insertText:, insertNewline, etc.
- (void)keyDown:(NSEvent*)event
{
	[self interpretKeyEvents:[NSArray arrayWithObject:event]];
}

- (void)insertText:(id)s
{
	NSAssert(
	        [s isKindOfClass:[NSString class]],
	        @"insertText: was passed a class other than NSString");
	NSString* string = s;
	NSLog(@"string: “%@”", string);
}

@end

int main()
{
	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

		NSMenu* menuBar = [[NSMenu alloc] init];
		NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
		[menuBar addItem:appMenuItem];
		NSMenu* appMenu = [[NSMenu alloc] init];
		appMenuItem.submenu = appMenu;

		NSApp.mainMenu = menuBar;

		NSMenuItem* quitMenuItem
		        = [[NSMenuItem alloc] initWithTitle:@"Quit metallll"
		                                     action:@selector(terminate:)
		                              keyEquivalent:@"q"];
		[appMenu addItem:quitMenuItem];

		NSRect rect = NSMakeRect(100, 100, 500, 400);

		NSWindowStyleMask style = NSWindowStyleMaskTitled
		        | NSWindowStyleMaskResizable
		        | NSWindowStyleMaskClosable;
		NSWindow* window
		        = [[NSWindow alloc] initWithContentRect:rect
		                                      styleMask:style
		                                        backing:NSBackingStoreBuffered
		                                          defer:NO];
		window.title = @"metalllllllllll";
		MainView* view = [[MainView alloc] initWithFrame:rect];
		window.contentView = view;

		// Zero alpha results in no window shadow, so we use “almost zero”.
		window.backgroundColor = [NSColor colorWithRed:0
		                                         green:0
		                                          blue:0
		                                         alpha:CGFLOAT_EPSILON];

		[window makeKeyAndOrderFront:nil];

		dispatch_async(dispatch_get_main_queue(), ^{
		    [NSApp activateIgnoringOtherApps:YES];
		});

		[NSApp run];
	}
}
