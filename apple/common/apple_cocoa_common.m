/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2013-2014 - Jason Fetters
 *  Copyright (C) 2011-2015 - Daniel De Matteis
 * 
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

#import <AvailabilityMacros.h>
#include <sys/stat.h>
#include <CoreFoundation/CFArray.h>
#include <CoreFoundation/CFString.h>
#import <Foundation/NSPathUtilities.h>
#include "CFExtensions.h"
#import "RetroArch_Apple.h"
#include "../../general.h"
#include "../../runloop.h"
#include "../../frontend/frontend.h"
#include "../../gfx/video_context_driver.h"

#ifndef __has_feature
/* Compatibility with non-Clang compilers. */
#define __has_feature(x) 0
#endif

#ifndef CF_RETURNS_RETAINED
#if __has_feature(attribute_cf_returns_retained)
#define CF_RETURNS_RETAINED __attribute__((cf_returns_retained))
#else
#define CF_RETURNS_RETAINED
#endif
#endif

NS_INLINE CF_RETURNS_RETAINED CFTypeRef CFBridgingRetainCompat(id X)
{
#if __has_feature(objc_arc)
	return (__bridge_retained CFTypeRef)X;
#else
	return X;
#endif
}

static NSSearchPathDirectory NSConvertFlagsCF(unsigned flags)
{
    switch (flags)
    {
        case CFDocumentDirectory:
            return NSDocumentDirectory;
    }
    
    return 0;
}

static NSSearchPathDomainMask NSConvertDomainFlagsCF(unsigned flags)
{
    switch (flags)
    {
        case CFUserDomainMask:
            return NSUserDomainMask;
    }
    
    return 0;
}

void CFTemporaryDirectory(char *buf, size_t sizeof_buf)
{
#if __has_feature(objc_arc)
    CFStringRef path = (__bridge_retained CFStringRef)NSTemporaryDirectory();
#else
    CFStringRef path = (CFStringRef)NSTemporaryDirectory();
#endif
    CFStringGetCString(path, buf, sizeof_buf, kCFStringEncodingUTF8);
}

void CFSearchPathForDirectoriesInDomains(unsigned flags,
        unsigned domain_mask, unsigned expand_tilde,
        char *buf, size_t sizeof_buf)
{
   CFTypeRef array_val = (CFTypeRef)CFBridgingRetainCompat(NSSearchPathForDirectoriesInDomains(NSConvertFlagsCF(flags), NSConvertDomainFlagsCF(domain_mask), (BOOL)expand_tilde));
   CFArrayRef array = array_val ? CFRetain(array_val) : NULL;
   CFTypeRef path_val = (CFTypeRef)CFArrayGetValueAtIndex(array, 0);
   CFStringRef path = path_val ? CFRetain(path_val) : NULL;
   if (!path || !array)
      return;
   
   CFStringGetCString(path, buf, sizeof_buf, kCFStringEncodingUTF8);
   CFRelease(path);
   CFRelease(array);
}

void apple_display_alert(const char *message, const char *title)
{
#ifdef IOS
   UIAlertView* alert = [[UIAlertView alloc] initWithTitle:BOXSTRING(title)
                                             message:BOXSTRING(message)
                                             delegate:nil
                                             cancelButtonTitle:BOXSTRING("OK")
                                             otherButtonTitles:nil];
   [alert show];
#else
   NSAlert* alert = [[NSAlert new] autorelease];
   
   [alert setMessageText:(*title) ? BOXSTRING(title) : BOXSTRING("RetroArch")];
   [alert setInformativeText:BOXSTRING(message)];
   [alert setAlertStyle:NSInformationalAlertStyle];
   [alert beginSheetModalForWindow:[RetroArch_OSX get].window
          modalDelegate:apple_platform
          didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:)
          contextInfo:nil];
   [[NSApplication sharedApplication] runModalForWindow:[alert window]];
#endif
}

// Number formatter class for setting strings
@implementation RANumberFormatter
- (id)initWithSetting:(const rarch_setting_t*)setting
{
   if ((self = [super init]))
   {
      [self setAllowsFloats:(setting->type == ST_FLOAT)];
      
      if (setting->flags & SD_FLAG_HAS_RANGE)
      {
         [self setMinimum:BOXFLOAT(setting->min)];
         [self setMaximum:BOXFLOAT(setting->max)];      
      }
   }
   
   return self;
}

- (BOOL)isPartialStringValid:(NSString*)partialString newEditingString:(NSString**)newString errorDescription:(NSString**)error
{
   unsigned i;
   bool hasDot = false;

   if (partialString.length)
      for (i = 0; i < partialString.length; i ++)
      {
         unichar ch = [partialString characterAtIndex:i];

         if (i == 0 && (!self.minimum || self.minimum.intValue < 0) && ch == '-')
            continue;
         else if (self.allowsFloats && !hasDot && ch == '.')
            hasDot = true;
         else if (!isdigit(ch))
            return NO;
      }

   return YES;
}

#ifdef IOS
- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
   NSString* text = (NSString*)[[textField text] stringByReplacingCharactersInRange:range withString:string];
   return [self isPartialStringValid:text newEditingString:nil errorDescription:nil];
}
#endif

@end

/* Define compatibility symbols and categories. */

//#if defined(MAC_OS_X_VERSION_10_7) || defined(__IPHONE_4_0)
#if defined(__IPHONE_4_0) && defined(IOS)
#define HAVE_AVFOUNDATION
#endif

#ifdef HAVE_AVFOUNDATION
#include <AVFoundation/AVCaptureSession.h>
#include <AVFoundation/AVCaptureDevice.h>
#include <AVFoundation/AVCaptureOutput.h>
#include <AVFoundation/AVCaptureInput.h>
#include <AVFoundation/AVMediaFormat.h>
#ifdef HAVE_OPENGLES
#include <CoreVideo/CVOpenGLESTextureCache.h>
#else
#include <CoreVideo/CVOpenGLTexture.h>
#endif
#endif

#if defined(OSX)

/* RAGameView is a container on iOS; 
 * on OSX these are both the same object
 */
#define g_view g_instance

#elif defined(IOS)

#include <GLKit/GLKit.h>
#include "../iOS/views.h"
#define ALMOST_INVISIBLE (.021f)
static GLKView *g_view;
static UIView *g_pause_indicator_view;
#endif

static RAGameView* g_instance;

#ifdef OSX
#include <OpenGL/CGLTypes.h>
#include <OpenGL/OpenGL.h>
#endif

#include "../../gfx/video_viewport.h"
#include "../../gfx/video_monitor.h"
#include "../../gfx/video_context_driver.h"
#include "../../gfx/gl_common.h"
#include "../../runloop.h"

//#define HAVE_NSOPENGL

#ifdef IOS
#define GLContextClass EAGLContext
#define GLFrameworkID CFSTR("com.apple.opengles")
#define RAScreen UIScreen

@interface EAGLContext (OSXCompat) @end
@implementation EAGLContext (OSXCompat)
+ (void)clearCurrentContext { [EAGLContext setCurrentContext:nil];  }
- (void)makeCurrentContext  { [EAGLContext setCurrentContext:self]; }
@end

#else


@interface NSScreen (IOSCompat) @end
@implementation NSScreen (IOSCompat)
- (CGRect)bounds
{
    CGRect cgrect  = NSRectToCGRect(self.frame);
    return CGRectMake(0, 0, CGRectGetWidth(cgrect), CGRectGetHeight(cgrect));
}
- (float) scale  { return 1.0f; }
@end

#define GLContextClass NSOpenGLContext
#define GLFrameworkID CFSTR("com.apple.opengl")
#define RAScreen NSScreen
#endif

static GLContextClass* g_hw_ctx;
static GLContextClass* g_context;

static int g_fast_forward_skips;
static bool g_is_syncing = true;
static bool g_use_hw_ctx;

#ifdef OSX
static bool g_has_went_fullscreen;
static NSOpenGLPixelFormat* g_format;
#endif

static unsigned g_minor = 0;
static unsigned g_major = 0;

#ifdef IOS
void apple_bind_game_view_fbo(void)
{
   if (g_context)
      [g_view bindDrawable];
}
#endif

static RAScreen* get_chosen_screen(void)
{
#if defined(OSX) && !defined(MAC_OS_X_VERSION_10_6)
	return [RAScreen mainScreen];
#else
   settings_t *settings = config_get_ptr();
   if (settings->video.monitor_index >= RAScreen.screens.count)
   {
      RARCH_WARN("video_monitor_index is greater than the number of connected monitors; using main screen instead.\n");
      return RAScreen.mainScreen;
   }
	
   NSArray *screens = [RAScreen screens];
   return (RAScreen*)[screens objectAtIndex:settings->video.monitor_index];
#endif
}

static void apple_gfx_ctx_update(void)
{
#ifdef OSX
#if MAC_OS_X_VERSION_10_7 && !defined(HAVE_NSOPENGL)
   CGLUpdateContext(g_context.CGLContextObj);
#else
	[g_context update];
#endif
#endif
}

static bool apple_gfx_ctx_init(void *data)
{
   (void)data;
    
#ifdef OSX
    
    NSOpenGLPixelFormatAttribute attributes [] = {
        NSOpenGLPFAColorSize, 24,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAllowOfflineRenderers,
        NSOpenGLPFADepthSize,
        (NSOpenGLPixelFormatAttribute)16, // 16 bit depth buffer
#ifdef MAC_OS_X_VERSION_10_7
        (g_major || g_minor) ? NSOpenGLPFAOpenGLProfile : 0,
        (g_major << 12) | (g_minor << 8),
#endif
        (NSOpenGLPixelFormatAttribute)0
    };
    
    g_format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    
#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
    if (g_format == nil)
    {
        /* NSOpenGLFPAAllowOfflineRenderers is 
         not supported on this OS version. */
        attributes[3] = (NSOpenGLPixelFormatAttribute)0;
        g_format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    }
#endif
    
    if (g_use_hw_ctx)
    {
        //g_hw_ctx  = [[NSOpenGLContext alloc] initWithFormat:g_format shareContext:nil];
    }
    g_context = [[NSOpenGLContext alloc] initWithFormat:g_format shareContext:(g_use_hw_ctx) ? g_hw_ctx : nil];
    [g_context setView:g_view];
#else
    g_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    g_view.context = g_context;
#endif
    
    [g_context makeCurrentContext];
   // Make sure the view was created
   [RAGameView get];
   return true;
}

static void apple_gfx_ctx_destroy(void *data)
{
   (void)data;

   [GLContextClass clearCurrentContext];

#if defined(IOS)
   g_view.context = nil;
#elif defined(OSX)
    [g_context clearDrawable];
    if (g_context)
        [g_context release];
    g_context = nil;
    if (g_format)
        [g_format release];
    g_format = nil;
    if (g_hw_ctx)
        [g_hw_ctx release];
    g_hw_ctx = nil;
#endif
   [GLContextClass clearCurrentContext];
   g_context = nil;
}



static bool apple_gfx_ctx_bind_api(void *data, enum gfx_ctx_api api, unsigned major, unsigned minor)
{
   (void)data;
#if defined(IOS)
   if (api != GFX_CTX_OPENGL_ES_API)
      return false;
#elif defined(OSX)
   if (api != GFX_CTX_OPENGL_API)
      return false;
#endif
    
   g_minor = minor;
   g_major = major;
  
   return true;
}

static void apple_gfx_ctx_swap_interval(void *data, unsigned interval)
{
   (void)data;
#ifdef IOS // < No way to disable Vsync on iOS?
           //   Just skip presents so fast forward still works.
   g_is_syncing = interval ? true : false;
   g_fast_forward_skips = interval ? 0 : 3;
#elif defined(OSX)
   GLint value = interval ? 1 : 0;
#ifdef HAVE_NSOPENGL
   [g_context setValues:&value forParameter:NSOpenGLCPSwapInterval];
#else
    CGLSetParameter(g_context.CGLContextObj, kCGLCPSwapInterval, &value);
#endif
    
#endif
}

static bool apple_gfx_ctx_set_video_mode(void *data, unsigned width, unsigned height, bool fullscreen)
{
   (void)data;
#ifdef OSX
   // TODO: Screen mode support
   
   if (fullscreen && !g_has_went_fullscreen)
   {
      [g_view enterFullScreenMode:get_chosen_screen() withOptions:nil];
      [NSCursor hide];
   }
   else if (!fullscreen && g_has_went_fullscreen)
   {
      [g_view exitFullScreenModeWithOptions:nil];
      [[g_view window] makeFirstResponder:g_view];
      [NSCursor unhide];
   }
   
   g_has_went_fullscreen = fullscreen;
   if (!g_has_went_fullscreen)
      [[g_view window] setContentSize:NSMakeSize(width, height)];
#endif

   // TODO: Maybe iOS users should be apple to show/hide the status bar here?

   return true;
}

float apple_gfx_ctx_get_native_scale(void)
{
    static float ret = 0.0f;
    SEL selector = NSSelectorFromString(BOXSTRING("nativeScale"));
    RAScreen *screen = (RAScreen*)get_chosen_screen();
    
    if (ret != 0.0f)
       return ret;
    if (!screen)
       return 0.0f;
    
   if ([screen respondsToSelector:selector])
   {
       NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:
                                   [[screen class] instanceMethodSignatureForSelector:selector]];
       [invocation setSelector:selector];
       [invocation setTarget:screen];
       [invocation invoke];
       [invocation getReturnValue:&ret];
       return ret;
   }
    
   ret = 1.0f;
   if ([screen respondsToSelector:@selector(scale)])
      ret = screen.scale;
   return ret;
}

static void apple_gfx_ctx_get_video_size(void *data, unsigned* width, unsigned* height)
{
   RAScreen *screen = (RAScreen*)get_chosen_screen();
   CGRect size = screen.bounds;
   gl_t *gl = (gl_t*)data;
   float screenscale = apple_gfx_ctx_get_native_scale();
	
   if (gl)
   {
#if defined(OSX)
      CGRect cgrect = NSRectToCGRect([g_view frame]);
      size = CGRectMake(0, 0, CGRectGetWidth(cgrect), CGRectGetHeight(cgrect));
#else
      size = g_view.bounds;
#endif
   }
    
   *width  = CGRectGetWidth(size)  * screenscale;
   *height = CGRectGetHeight(size) * screenscale;
}

static void apple_gfx_ctx_update_window_title(void *data)
{
   static char buf[128], buf_fps[128];
   bool got_text = video_monitor_get_fps(buf, sizeof(buf),
         buf_fps, sizeof(buf_fps));
   settings_t *settings = config_get_ptr();

   (void)got_text;

#ifdef OSX
   static const char* const text = buf; /* < Can't access buffer directly in the block */
   if (got_text)
       [[g_view window] setTitle:[NSString stringWithCString:text encoding:NSUTF8StringEncoding]];
#endif
    if (settings->fps_show)
        rarch_main_msg_queue_push(buf_fps, 1, 1, false);
}

static bool apple_gfx_ctx_get_metrics(void *data, enum display_metric_types type,
            float *value)
{
#ifdef OSX
    RAScreen *screen           = [RAScreen mainScreen];
    NSDictionary *description  = [screen deviceDescription];
    NSSize displayPixelSize    = [[description objectForKey:NSDeviceSize] sizeValue];
    CGSize displayPhysicalSize = CGDisplayScreenSize(
        [[description objectForKey:@"NSScreenNumber"] unsignedIntValue]);
    
    float   displayWidth       = displayPixelSize.width;
    float   displayHeight      = displayPixelSize.height;
    float   physicalWidth      = displayPhysicalSize.width;
    float   physicalHeight     = displayPhysicalSize.height;
#elif defined(IOS)
    float   scale              = apple_gfx_ctx_get_native_scale();
    CGRect screenRect          = [[UIScreen mainScreen] bounds];
    
    float   displayWidth       = screenRect.size.width;
    float   displayHeight      = screenRect.size.height;
    float   physicalWidth      = screenRect.size.width * scale;
    float   physicalHeight     = screenRect.size.height * scale;
#endif
    
    (void)displayHeight;
    
    switch (type)
    {
        case DISPLAY_METRIC_NONE:
            return false;
        case DISPLAY_METRIC_MM_WIDTH:
            *value = physicalWidth;
            break;
        case DISPLAY_METRIC_MM_HEIGHT:
            *value = physicalHeight;
            break;
        case DISPLAY_METRIC_DPI:
            /* 25.4 mm in an inch. */
            *value = (displayWidth/ physicalWidth) * 25.4f;
            break;
        default:
            *value = 0;
            return false;
    }
    
    return true;
}

static bool apple_gfx_ctx_has_focus(void *data)
{
   (void)data;
#ifdef IOS
    return ([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive);
#else
    return [NSApp isActive];
#endif
}

static bool apple_gfx_ctx_suppress_screensaver(void *data, bool enable)
{
   (void)data;
   (void)enable;

   return false;
}

static bool apple_gfx_ctx_has_windowed(void *data)
{
   (void)data;

#ifdef IOS
   return false;
#else
   return true;
#endif
}

static void apple_gfx_ctx_swap_buffers(void *data)
{
   if (!(--g_fast_forward_skips < 0))
      return;
    
#ifdef OSX
#ifdef HAVE_NSOPENGL
    [g_context flushBuffer];
#else
    if (g_context.CGLContextObj)
        CGLFlushDrawable(g_context.CGLContextObj);
#endif
#endif
    
   g_fast_forward_skips = g_is_syncing ? 0 : 3;
}

static gfx_ctx_proc_t apple_gfx_ctx_get_proc_address(const char *symbol_name)
{
   return (gfx_ctx_proc_t)CFBundleGetFunctionPointerForName(CFBundleGetBundleWithIdentifier(GLFrameworkID),
   (
#if MAC_OS_X_VERSION_10_7
#if __has_feature(objc_arc)
         __bridge
#endif
#endif
CFStringRef)BOXSTRING(symbol_name)
         );
}

static void apple_gfx_ctx_check_window(void *data, bool *quit,
      bool *resize, unsigned *width, unsigned *height, unsigned frame_count)
{
   unsigned new_width, new_height;
   (void)frame_count;

   *quit = false;

   apple_gfx_ctx_get_video_size(data, &new_width, &new_height);
   if (new_width != *width || new_height != *height)
   {
      *width  = new_width;
      *height = new_height;
      *resize = true;
   }
}

static void apple_gfx_ctx_set_resize(void *data, unsigned width, unsigned height)
{
   (void)data;
   (void)width;
   (void)height;
}

static void apple_gfx_ctx_input_driver(void *data, const input_driver_t **input, void **input_data)
{
   (void)data;
   *input = NULL;
   *input_data = NULL;
}

static void apple_gfx_ctx_bind_hw_render(void *data, bool enable)
{
   (void)data;
   g_use_hw_ctx = enable;
    
    if (enable)
        [g_hw_ctx makeCurrentContext];
    else
        [g_context makeCurrentContext];
}

// The apple_* functions are implemented in apple/RetroArch/RAGameView.m
const gfx_ctx_driver_t gfx_ctx_apple = {
   apple_gfx_ctx_init,
   apple_gfx_ctx_destroy,
   apple_gfx_ctx_bind_api,
   apple_gfx_ctx_swap_interval,
   apple_gfx_ctx_set_video_mode,
   apple_gfx_ctx_get_video_size,
   NULL, /* get_video_output_size */
   NULL, /* get_video_output_prev */
   NULL, /* get_video_output_next */
   apple_gfx_ctx_get_metrics,
   NULL,
   apple_gfx_ctx_update_window_title,
   apple_gfx_ctx_check_window,
   apple_gfx_ctx_set_resize,
   apple_gfx_ctx_has_focus,
   apple_gfx_ctx_suppress_screensaver,
   apple_gfx_ctx_has_windowed,
   apple_gfx_ctx_swap_buffers,
   apple_gfx_ctx_input_driver,
   apple_gfx_ctx_get_proc_address,
   NULL,
   "apple",
   apple_gfx_ctx_bind_hw_render,
};

@implementation RAGameView
+ (RAGameView*)get
{
   if (!g_instance)
      g_instance = [RAGameView new];
   
   return g_instance;
}

- (id)init
{
   self = [super init];
   
#if defined(OSX)
   [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
#elif defined(IOS)
   /* iOS Pause menu and lifecycle. */
   UINib *xib = (UINib*)[UINib nibWithNibName:BOXSTRING("PauseIndicatorView") bundle:nil];
   g_pause_indicator_view = [[xib instantiateWithOwner:[RetroArch_iOS get] options:nil] lastObject];
   
   g_view = [GLKView new];
   g_view.multipleTouchEnabled = YES;
   g_view.enableSetNeedsDisplay = NO;
   [g_view addSubview:g_pause_indicator_view];
   
   self.view = g_view;
   
   [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showPauseIndicator) name:UIApplicationWillEnterForegroundNotification object:nil];
#endif
   
   return self;
}

#ifdef OSX

static void apple_gfx_ctx_update(void);

- (void)setFrame:(NSRect)frameRect
{
   [super setFrame:frameRect];

   apple_gfx_ctx_update();
}

/* Stop the annoying sound when pressing a key. */
- (BOOL)acceptsFirstResponder
{
   return YES;
}

- (BOOL)isFlipped
{
   return YES;
}

- (void)keyDown:(NSEvent*)theEvent
{
}

#elif defined(IOS)
- (void)viewDidAppear:(BOOL)animated
{
   /* Pause Menus. */
   [self showPauseIndicator];
}

- (void)showPauseIndicator
{
   g_pause_indicator_view.alpha = 1.0f;
   [NSObject cancelPreviousPerformRequestsWithTarget:g_instance];
   [g_instance performSelector:@selector(hidePauseButton) withObject:g_instance afterDelay:3.0f];
}

- (void)viewWillLayoutSubviews
{
   UIInterfaceOrientation orientation = self.interfaceOrientation;
   CGRect screenSize = [[UIScreen mainScreen] bounds];
   float width = ((int)orientation < 3) ? CGRectGetWidth(screenSize) : CGRectGetHeight(screenSize);
   float height = ((int)orientation < 3) ? CGRectGetHeight(screenSize) : CGRectGetWidth(screenSize);
   float tenpctw = width / 10.0f;
   float tenpcth = height / 10.0f;
   
   g_pause_indicator_view.frame = CGRectMake(tenpctw * 4.0f, 0.0f, tenpctw * 2.0f, tenpcth);
   [g_pause_indicator_view viewWithTag:1].frame = CGRectMake(0, 0, tenpctw * 2.0f, tenpcth);
}

- (void)hidePauseButton
{
   [UIView animateWithDuration:0.2
      animations:^{ g_pause_indicator_view.alpha = ALMOST_INVISIBLE; }
      completion:^(BOOL finished) { }
   ];
}

/* NOTE: This version runs on iOS6+. */
- (NSUInteger)supportedInterfaceOrientations
{
   return apple_frontend_settings.orientation_flags;
}

/* NOTE: This version runs on iOS2-iOS5, but not iOS6+. */
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
   switch (interfaceOrientation)
   {
      case UIInterfaceOrientationPortrait:
         return (apple_frontend_settings.orientation_flags & UIInterfaceOrientationMaskPortrait);
      case UIInterfaceOrientationPortraitUpsideDown:
         return (apple_frontend_settings.orientation_flags & UIInterfaceOrientationMaskPortraitUpsideDown);
      case UIInterfaceOrientationLandscapeLeft:
         return (apple_frontend_settings.orientation_flags & UIInterfaceOrientationMaskLandscapeLeft);
      case UIInterfaceOrientationLandscapeRight:
         return (apple_frontend_settings.orientation_flags & UIInterfaceOrientationMaskLandscapeRight);

      default:
         return (apple_frontend_settings.orientation_flags & UIInterfaceOrientationMaskAll);
   }
   
   return YES;
}

#endif

#ifdef HAVE_AVFOUNDATION

#ifndef GL_BGRA
#define GL_BGRA 0x80E1
#endif

#ifdef HAVE_OPENGLES
#define RCVOpenGLTextureCacheCreateTextureFromImage CVOpenGLESTextureCacheCreateTextureFromImage
#define RCVOpenGLTextureGetName CVOpenGLESTextureGetName
#define RCVOpenGLTextureCacheFlush CVOpenGLESTextureCacheFlush
#define RCVOpenGLTextureCacheCreate CVOpenGLESTextureCacheCreate
#define RCVOpenGLTextureRef CVOpenGLESTextureRef
#define RCVOpenGLTextureCacheRef CVOpenGLESTextureCacheRef
#if COREVIDEO_USE_EAGLCONTEXT_CLASS_IN_API
#define RCVOpenGLGetCurrentContext() (CVEAGLContext)(g_context)
#else
#define RCVOpenGLGetCurrentContext() (__bridge void *)(g_context)
#endif
#else
#define RCVOpenGLTextureCacheCreateTextureFromImage CVOpenGLTextureCacheCreateTextureFromImage
#define RCVOpenGLTextureGetName CVOpenGLTextureGetName
#define RCVOpenGLTextureCacheFlush CVOpenGLTextureCacheFlush
#define RCVOpenGLTextureCacheCreate CVOpenGLTextureCacheCreate
#define RCVOpenGLTextureRef CVOpenGLTextureRef
#define RCVOpenGLTextureCacheRef CVOpenGLTextureCacheRef
#define RCVOpenGLGetCurrentContext() CGLGetCurrentContext(), CGLGetPixelFormat(CGLGetCurrentContext())
#endif

static AVCaptureSession *_session;
static NSString *_sessionPreset;
RCVOpenGLTextureCacheRef textureCache;
GLuint outputTexture;
static bool newFrame = false;

extern void event_process_camera_frame(void* pixelBufferPtr);

void event_process_camera_frame(void* pixelBufferPtr)
{
    CVReturn ret;
    RCVOpenGLTextureRef renderTexture;
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)pixelBufferPtr;
    size_t width  = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    (void)width;
    (void)height;
    
    /*TODO - rewrite all this.
     *
     * create a texture from our render target.
     * textureCache will be what you previously 
     * made with RCVOpenGLTextureCacheCreate.
     */
#ifdef HAVE_OPENGLES
    ret = RCVOpenGLTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                      textureCache, pixelBuffer, NULL, GL_TEXTURE_2D,
                                                      GL_RGBA, (GLsizei)width, (GLsizei)height,
                                                      GL_BGRA, GL_UNSIGNED_BYTE, 0, &renderTexture);
#else
    ret = RCVOpenGLTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                      textureCache, pixelBuffer, 0, &renderTexture);
#endif

    if (!renderTexture || ret)
    {
        RARCH_ERR("[apple_camera]: RCVOpenGLTextureCacheCreateTextureFromImage failed.\n");
        return;
    }
    
    outputTexture = RCVOpenGLTextureGetName(renderTexture);
    glBindTexture(GL_TEXTURE_2D, outputTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NewCameraTextureReady" object:nil];
    newFrame = true;
    
    glBindTexture(GL_TEXTURE_2D, 0);
    
    RCVOpenGLTextureCacheFlush(textureCache, 0);

    CFRelease(renderTexture);
    CFRelease(pixelBuffer);

    pixelBuffer = 0;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    // TODO: Don't post if event queue is full
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CVPixelBufferRetain(CMSampleBufferGetImageBuffer(sampleBuffer));
    event_process_camera_frame(pixelBuffer);
}

/* TODO - add void param to onCameraInit so we can pass g_context. */
- (void) onCameraInit
{
    NSError *error;
    AVCaptureVideoDataOutput * dataOutput;
    AVCaptureDeviceInput *input;
    AVCaptureDevice *videoDevice;

    CVReturn ret = RCVOpenGLTextureCacheCreate(kCFAllocatorDefault, NULL,
    RCVOpenGLGetCurrentContext(), NULL, &textureCache);
    (void)ret;
    
    //-- Setup Capture Session.
    _session = [[AVCaptureSession alloc] init];
    [_session beginConfiguration];
    
    // TODO: dehardcode this based on device capabilities
    _sessionPreset = AVCaptureSessionPreset640x480;
    
    //-- Set preset session size.
    [_session setSessionPreset:_sessionPreset];
    
    //-- Creata a video device and input from that Device.  Add the input to the capture session.
    videoDevice = (AVCaptureDevice*)[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (videoDevice == nil)
        assert(0);
    
    //-- Add the device to the session.
    input = (AVCaptureDeviceInput*)[AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
    if (error)
    {
        RARCH_ERR("video device input %s\n", error.localizedDescription.UTF8String);
        assert(0);
    }
    
    [_session addInput:input];
    
    /* Create the output for the capture session. */
    dataOutput = (AVCaptureVideoDataOutput*)[[AVCaptureVideoDataOutput alloc] init];
    [dataOutput setAlwaysDiscardsLateVideoFrames:NO]; /* Probably want to set this to NO when recording. */
    
	[dataOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    
    /* Set dispatch to be on the main thread so OpenGL can do things with the data. */
    [dataOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    
    [_session addOutput:dataOutput];
    [_session commitConfiguration];
}

- (void) onCameraStart
{
    [_session startRunning];
}

- (void) onCameraStop
{
    [_session stopRunning];
}

- (void) onCameraFree
{
    RCVOpenGLTextureCacheFlush(textureCache, 0);
    CFRelease(textureCache);
}
#endif

#ifdef HAVE_LOCATION
#include <CoreLocation/CoreLocation.h>

static CLLocationManager *locationManager;
static bool locationChanged;
static CLLocationDegrees currentLatitude;
static CLLocationDegrees currentLongitude;
static CLLocationAccuracy currentHorizontalAccuracy;
static CLLocationAccuracy currentVerticalAccuracy;

- (bool)onLocationHasChanged
{
   bool hasChanged = locationChanged;
    
   if (hasChanged)
      locationChanged = false;
    
   return hasChanged;
}

- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation fromLocation:(CLLocation *)oldLocation
{
    locationChanged = true;
    currentLatitude = newLocation.coordinate.latitude;
    currentLongitude = newLocation.coordinate.longitude;
    currentHorizontalAccuracy = newLocation.horizontalAccuracy;
    currentVerticalAccuracy = newLocation.verticalAccuracy;
    RARCH_LOG("didUpdateToLocation - latitude %f, longitude %f\n", (float)currentLatitude, (float)currentLongitude);
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    CLLocation *location = (CLLocation*)[locations objectAtIndex:([locations count] - 1)];
    
    locationChanged = true;
    currentLatitude  = [location coordinate].latitude;
    currentLongitude = [location coordinate].longitude;
    currentHorizontalAccuracy = location.horizontalAccuracy;
    currentVerticalAccuracy = location.verticalAccuracy;
    RARCH_LOG("didUpdateLocations - latitude %f, longitude %f\n", (float)currentLatitude, (float)currentLongitude);
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
   RARCH_LOG("didFailWithError - %s\n", [[error localizedDescription] UTF8String]);
}

- (void)locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager
{
   RARCH_LOG("didPauseLocationUpdates\n");
}

- (void)locationManagerDidResumeLocationUpdates:(CLLocationManager *)manager
{
   RARCH_LOG("didResumeLocationUpdates\n");
}

- (void)onLocationInit
{
    // Create the location manager if this object does not
    // already have one.
    
    if (locationManager == nil)
        locationManager = [[CLLocationManager alloc] init];
    locationManager.delegate = self;
    locationManager.desiredAccuracy = kCLLocationAccuracyBest;
    locationManager.distanceFilter = kCLDistanceFilterNone;
    [locationManager startUpdatingLocation];
}
#endif

@end

#ifdef HAVE_AVFOUNDATION
typedef struct apple_camera
{
  void *empty;
} applecamera_t;

static void *apple_camera_init(const char *device, uint64_t caps, unsigned width, unsigned height)
{
   applecamera_t *applecamera;
    
   if ((caps & (1ULL << RETRO_CAMERA_BUFFER_OPENGL_TEXTURE)) == 0)
   {
      RARCH_ERR("applecamera returns OpenGL texture.\n");
      return NULL;
   }

   applecamera = (applecamera_t*)calloc(1, sizeof(applecamera_t));
   if (!applecamera)
      return NULL;

   [[RAGameView get] onCameraInit];

   return applecamera;
}

static void apple_camera_free(void *data)
{
   applecamera_t *applecamera = (applecamera_t*)data;
    
   [[RAGameView get] onCameraFree];

   if (applecamera)
      free(applecamera);
   applecamera = NULL;
}

static bool apple_camera_start(void *data)
{
   (void)data;

   [[RAGameView get] onCameraStart];

   return true;
}

static void apple_camera_stop(void *data)
{
   [[RAGameView get] onCameraStop];
}

static bool apple_camera_poll(void *data, retro_camera_frame_raw_framebuffer_t frame_raw_cb,
      retro_camera_frame_opengl_texture_t frame_gl_cb)
{

   (void)data;
   (void)frame_raw_cb;

   if (frame_gl_cb && newFrame)
   {
	   // FIXME: Identity for now. Use proper texture matrix as returned by iOS Camera (if at all?).
	   static const float affine[] = {
		   1.0f, 0.0f, 0.0f,
		   0.0f, 1.0f, 0.0f,
		   0.0f, 0.0f, 1.0f
	   };
       
	   frame_gl_cb(outputTexture, GL_TEXTURE_2D, affine);
       newFrame = false;
   }

   return true;
}

camera_driver_t camera_apple = {
   apple_camera_init,
   apple_camera_free,
   apple_camera_start,
   apple_camera_stop,
   apple_camera_poll,
   "apple",
};
#endif

#ifdef HAVE_LOCATION
typedef struct apple_location
{
	void *empty;
} applelocation_t;

static void *apple_location_init(void)
{
	applelocation_t *applelocation = (applelocation_t*)calloc(1, sizeof(applelocation_t));
	if (!applelocation)
		return NULL;
    
   [[RAGameView get] onLocationInit];
	
	return applelocation;
}

static void apple_location_set_interval(void *data, unsigned interval_update_ms, unsigned interval_distance)
{
   (void)data;
	
   locationManager.distanceFilter = interval_distance ? interval_distance : kCLDistanceFilterNone;
}

static void apple_location_free(void *data)
{
	applelocation_t *applelocation = (applelocation_t*)data;
	
   /* TODO - free location manager? */
	
	if (applelocation)
		free(applelocation);
	applelocation = NULL;
}

static bool apple_location_start(void *data)
{
	(void)data;
	
   [locationManager startUpdatingLocation];
	return true;
}

static void apple_location_stop(void *data)
{
	(void)data;
	
   [locationManager stopUpdatingLocation];
}

static bool apple_location_get_position(void *data, double *lat, double *lon, double *horiz_accuracy,
      double *vert_accuracy)
{
	(void)data;

   bool ret = [[RAGameView get] onLocationHasChanged];

   if (!ret)
      goto fail;
	
   *lat            = currentLatitude;
   *lon            = currentLongitude;
   *horiz_accuracy = currentHorizontalAccuracy;
   *vert_accuracy  = currentVerticalAccuracy;
   return true;

fail:
   *lat            = 0.0;
   *lon            = 0.0;
   *horiz_accuracy = 0.0;
   *vert_accuracy  = 0.0;
   return false;
}

location_driver_t location_apple = {
	apple_location_init,
	apple_location_free,
	apple_location_start,
	apple_location_stop,
	apple_location_get_position,
	apple_location_set_interval,
	"apple",
};
#endif

