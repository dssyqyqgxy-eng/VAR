// HKSmartOptimizer.m - 空洞骑士智能优化器（纯净版）
// 自适应帧率 + 分场景分辨率 + 自动场景检测

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>

// ==========================================
// 1. 场景枚举
// ==========================================
typedef NS_ENUM(NSInteger, HKSceneType) {
    HKSceneTypeUnknown = 0,
    HKSceneTypeCrossroads, HKSceneTypeGreenpath, HKSceneTypeFungal,
    HKSceneTypeCity, HKSceneTypeDeepnest, HKSceneTypeMines,
    HKSceneTypeCliffs, HKSceneTypeRestingGrounds, HKSceneTypeWaterways,
    HKSceneTypeAbyss, HKSceneTypeWhitePalace, HKSceneTypeHive,
    HKSceneTypeGodhome, HKSceneTypeGrimm, HKSceneTypeDream,
    HKSceneTypeColosseum, HKSceneTypeTutorial, HKSceneTypeTown
};

// ==========================================
// 2. 场景配置
// ==========================================
typedef struct {
    float resolutionScale;  // 1.0=原生, 1.5=降1/3, 2.0=降一半
    int   targetFPS;        // 目标帧率
} HKSceneConfig;

// ==========================================
// 3. 全局变量
// ==========================================
static CADisplayLink* g_monitorLink    = nil;
static int   g_deviceMaxFPS            = 60;
static float g_resolutionScale         = 1.0f;
static HKSceneType g_currentScene      = HKSceneTypeUnknown;
static NSDictionary* g_sceneConfigs    = nil;
static BOOL g_initialized              = NO;

// ==========================================
// 4. 设备检测
// ==========================================
static int DetectDeviceMaxFPS(void) {
    UIScreen* screen = [UIScreen mainScreen];
    int maxFPS = 60;
    if (@available(iOS 15.0, *)) {
        maxFPS = (int)screen.maximumFramesPerSecond;
    } else if (@available(iOS 10.3, *)) {
        maxFPS = (int)screen.maximumFramesPerSecond;
    }
    if (maxFPS < 60)  maxFPS = 60;
    if (maxFPS > 120) maxFPS = 120;
    return maxFPS;
}

// ==========================================
// 5. 场景配置表
// ==========================================
static void SetupSceneConfigs(void) {
    float resGood = 1.2f;
    float resMid  = 1.5f;
    float resLow  = 1.8f;
    int   fpsHigh = g_deviceMaxFPS;
    int   fpsMid  = g_deviceMaxFPS >= 120 ? 60 : g_deviceMaxFPS;
    int   fpsLow  = 30;

    g_sceneConfigs = @{
        @(HKSceneTypeCrossroads):     @[@(resGood), @(fpsHigh)],
        @(HKSceneTypeGreenpath):      @[@(resGood), @(fpsHigh)],
        @(HKSceneTypeFungal):         @[@(resMid),  @(fpsMid)],
        @(HKSceneTypeCity):           @[@(resGood), @(fpsHigh)],
        @(HKSceneTypeDeepnest):       @[@(resLow),  @(fpsLow)],
        @(HKSceneTypeMines):          @[@(resGood), @(fpsHigh)],
        @(HKSceneTypeCliffs):         @[@(resGood), @(fpsHigh)],
        @(HKSceneTypeRestingGrounds): @[@(resMid),  @(fpsMid)],
        @(HKSceneTypeWaterways):      @[@(resMid),  @(fpsMid)],
        @(HKSceneTypeAbyss):          @[@(resLow),  @(fpsLow)],
        @(HKSceneTypeWhitePalace):    @[@(resMid),  @(fpsMid)],
        @(HKSceneTypeHive):           @[@(resGood), @(fpsHigh)],
        @(HKSceneTypeGodhome):        @[@(resLow),  @(fpsLow)],
        @(HKSceneTypeGrimm):          @[@(resMid),  @(fpsLow)],
        @(HKSceneTypeDream):          @[@(resLow),  @(fpsLow)],
        @(HKSceneTypeColosseum):      @[@(resMid),  @(fpsLow)],
        @(HKSceneTypeTutorial):       @[@(1.0f),    @(fpsHigh)],
        @(HKSceneTypeTown):           @[@(1.0f),    @(fpsHigh)],
        @(HKSceneTypeUnknown):        @[@(resGood), @(fpsHigh)],
    };
}

static HKSceneConfig GetSceneConfig(HKSceneType scene) {
    NSArray* config = g_sceneConfigs[@(scene)];
    if (!config) config = g_sceneConfigs[@(HKSceneTypeUnknown)];
    HKSceneConfig cfg;
    cfg.resolutionScale = [config[0] floatValue];
    cfg.targetFPS       = [config[1] intValue];
    return cfg;
}

// ==========================================
// 6. 场景检测
// ==========================================
static HKSceneType DetectCurrentScene(void) {
    Class sceneManager = NSClassFromString(@"UnityEngine.SceneManagement.SceneManager");
    if (!sceneManager) return g_currentScene;

    SEL getActiveScene = NSSelectorFromString(@"GetActiveScene");
    if (![sceneManager respondsToSelector:getActiveScene]) return g_currentScene;

    NSMethodSignature* sig = [sceneManager methodSignatureForSelector:getActiveScene];
    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:sceneManager];
    [inv setSelector:getActiveScene];
    [inv invoke];

    id __unsafe_unretained activeScene = nil;
    [inv getReturnValue:&activeScene];
    if (!activeScene) return g_currentScene;

    SEL getName = NSSelectorFromString(@"name");
    if (![activeScene respondsToSelector:getName]) return g_currentScene;

    NSMethodSignature* sig2 = [activeScene methodSignatureForSelector:getName];
    NSInvocation* inv2 = [NSInvocation invocationWithMethodSignature:sig2];
    [inv2 setTarget:activeScene];
    [inv2 setSelector:getName];
    [inv2 invoke];

    NSString __unsafe_unretained* sceneName = nil;
    [inv2 getReturnValue:&sceneName];
    if (!sceneName) return g_currentScene;

    if ([sceneName containsString:@"Crossroads"])                return HKSceneTypeCrossroads;
    if ([sceneName containsString:@"Greenpath"] || [sceneName containsString:@"Queen"]) return HKSceneTypeGreenpath;
    if ([sceneName containsString:@"Fungus"])                    return HKSceneTypeFungal;
    if ([sceneName containsString:@"City"] || [sceneName containsString:@"Ruins"]) return HKSceneTypeCity;
    if ([sceneName containsString:@"Deepnest"])                  return HKSceneTypeDeepnest;
    if ([sceneName containsString:@"Mines"] || [sceneName containsString:@"Crystal"]) return HKSceneTypeMines;
    if ([sceneName containsString:@"Cliffs"])                    return HKSceneTypeCliffs;
    if ([sceneName containsString:@"RestingGrounds"])            return HKSceneTypeRestingGrounds;
    if ([sceneName containsString:@"Waterways"])                 return HKSceneTypeWaterways;
    if ([sceneName containsString:@"Abyss"])                     return HKSceneTypeAbyss;
    if ([sceneName containsString:@"White_Palace"])              return HKSceneTypeWhitePalace;
    if ([sceneName containsString:@"Hive"])                      return HKSceneTypeHive;
    if ([sceneName containsString:@"GG_"] || [sceneName containsString:@"Gods_Glory"]) return HKSceneTypeGodhome;
    if ([sceneName containsString:@"Grimm"])                     return HKSceneTypeGrimm;
    if ([sceneName containsString:@"Dream_"])                    return HKSceneTypeDream;
    if ([sceneName containsString:@"Colosseum"])                 return HKSceneTypeColosseum;
    if ([sceneName containsString:@"Tutorial"])                  return HKSceneTypeTutorial;
    if ([sceneName containsString:@"Town"])                      return HKSceneTypeTown;

    return g_currentScene;
}

// ==========================================
// 7. 分辨率设置
// ==========================================
static void SetResolutionScale(float scale) {
    if (fabs(scale - g_resolutionScale) < 0.05f) return;
    g_resolutionScale = scale;

    dispatch_async(dispatch_get_main_queue(), ^{
        Class unityView = objc_getClass("UnityView");
        if (!unityView) return;

        UIWindow* window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene* s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) { window = s.windows.firstObject; break; }
            }
        }
        if (!window) window = [UIApplication sharedApplication].windows.firstObject;
        if (!window) return;

        for (UIView* v in window.subviews) {
            if ([v isKindOfClass:unityView]) {
                v.contentScaleFactor = scale;
                break;
            }
        }
    });
}

// ==========================================
// 8. 帧率锁定
// ==========================================
static void LockFrameRate(int fps) {
    if (fps == g_targetFPS) return;
    g_targetFPS = fps;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 15.0, *)) {
            [UIScreen mainScreen].maximumFramesPerSecond = fps;
        }
    });
}

// ==========================================
// 9. 应用场景配置
// ==========================================
static void ApplySceneConfig(HKSceneType scene) {
    HKSceneConfig cfg = GetSceneConfig(scene);
    SetResolutionScale(cfg.resolutionScale);
    LockFrameRate(cfg.targetFPS);
}

// ==========================================
// 10. 帧回调（仅检测场景切换）
// ==========================================
@interface HKMonitorTarget : NSObject
@end
@implementation HKMonitorTarget
- (void)onFrame:(CADisplayLink*)link {
    static int counter = 0;
    if (++counter % 120 == 0) {  // 每2秒检测一次
        HKSceneType newScene = DetectCurrentScene();
        if (newScene != g_currentScene) {
            g_currentScene = newScene;
            ApplySceneConfig(g_currentScene);
        }
    }
}
@end

// ==========================================
// 11. 主初始化
// ==========================================
__attribute__((constructor))
static void InitSmartOptimizer(void) {
    if (g_initialized) return;
    g_initialized = YES;

    g_deviceMaxFPS = DetectDeviceMaxFPS();
    SetupSceneConfigs();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        g_currentScene = DetectCurrentScene();
        ApplySceneConfig(g_currentScene);

        HKMonitorTarget* target = [[HKMonitorTarget alloc] init];
        g_monitorLink = [CADisplayLink displayLinkWithTarget:target selector:@selector(onFrame:)];
        [g_monitorLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}
