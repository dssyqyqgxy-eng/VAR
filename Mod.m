// Mod.m - 空洞骑士 GTE 版全功能 Mod（完整版）
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <pthread.h>
#import <sys/mman.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>

// ========== 已确认精确偏移 ==========
#define HERO_TAKEDAMAGE_RVA        0x10218A0
#define SHADOWDASH_RVA             0x102D4DC
#define ANIM_PLAY_RVA              0x1314A7C
#define ENEMY_APPLY_EXTRA_DAMAGE   0x1022A58  // HealthManager.ApplyExtraDamage

#define ATK_OFF                    0x214
#define HAS_SHD                    0x15B
#define CAN_SHD                    0x124
#define SHD_COOLDOWN               0x80
#define SHD_TIMER                  0x20C
#define ENEMY_HP                   0xE8

// ========== 类型 ==========
typedef void (*VoidFunc)(void);
typedef void (*TakeDamageFunc)(void*, void*);
typedef void (*AnimPlayFunc)(void*, void*, float, float);
typedef void (*ApplyExtraDamageFunc)(void*, int);

// ========== 全局 ==========
static VoidFunc orig_ShadowDash = NULL;
static TakeDamageFunc orig_HeroTakeDamage = NULL;
static AnimPlayFunc orig_AnimPlay = NULL;
static ApplyExtraDamageFunc orig_ApplyExtraDamage = NULL;
static void* g_hero = NULL;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static BOOL g_hooks_done = NO;

// ========== 前向声明 ==========
@interface UnityAppController : NSObject
- (void)applicationDidBecomeActive:(id)arg;
@end
static void (*orig_becomeActive)(id, SEL, id) = NULL;

// ========== 获取基址 ==========
static uint64_t GetBase(void) {
    for (int i = 0; i < _dyld_image_count(); i++)
        if (strstr(_dyld_get_image_name(i), "HollowKnight.app/HollowKnight"))
            return _dyld_get_image_vmaddr_slide(i);
    return 0;
}

static BOOL Ok(void* a) {
    uintptr_t p = (uintptr_t)a;
    return a && p > 0x100000000 && p < 0x800000000;
}

static void W(void* a, size_t s) {
    vm_protect(mach_task_self(), (vm_address_t)a, s, 0, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
}

static void Hook(void* tgt, void* fn, void** orig) {
    if (!Ok(tgt)) return;
    void* tr = mmap(NULL, 32, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0);
    if (tr == MAP_FAILED) return;
    *orig = tr; W(tr, 32);
    memcpy(tr, tgt, 16);
    uint8_t* c = (uint8_t*)tr + 16;
    c[0]=0x50;c[1]=0x00;c[2]=0x00;c[3]=0x58;
    c[4]=0x00;c[5]=0x02;c[6]=0x1F;c[7]=0xD6;
    *(void**)(c+8) = (uint8_t*)tgt + 16;
    W(tgt, 16);
    uint32_t* x = (uint32_t*)tgt;
    x[0]=0x58000050; x[1]=0xD61F0200;
    ((void**)x)[1] = fn;
    sys_icache_invalidate(tgt, 16);
}

// ========== 修改玩家属性 ==========
static void ModHero(void* h) {
    if (!Ok(h)) return;
    uintptr_t p = (uintptr_t)h;
    float* atk = (float*)(p+ATK_OFF);
    bool* hs = (bool*)(p+HAS_SHD);
    bool* cs = (bool*)(p+CAN_SHD);
    float* timer = (float*)(p+SHD_TIMER);
    float* cooldown = (float*)(p+SHD_COOLDOWN);
    if (Ok(atk)) *atk = 0.15f;
    if (Ok(hs)) *hs = true;
    if (Ok(cs)) *cs = true;
    if (Ok(timer)) *timer = 0.0f;
    if (Ok(cooldown)) *cooldown = 0.0f;
}

// ========== Hook 函数 ==========
static void hk_ShadowDash(void) {
    pthread_mutex_lock(&g_lock);
    ModHero(g_hero);
    pthread_mutex_unlock(&g_lock);
    if (orig_ShadowDash) orig_ShadowDash();
}

static void hk_TakeDamage(void* self, void* hit) {
    pthread_mutex_lock(&g_lock);
    g_hero = self;
    ModHero(self);
    pthread_mutex_unlock(&g_lock);
    if (orig_HeroTakeDamage) orig_HeroTakeDamage(self, hit);
}

static void hk_Anim(void* a, void* c, float s, float f) {
    if (orig_AnimPlay) orig_AnimPlay(a, c, s, f * 1.8f);
}

// ========== Boss 血量翻倍 ==========
static void hk_ApplyExtraDamage(void* enemy, int damage) {
    if (enemy && Ok(enemy)) {
        uintptr_t p = (uintptr_t)enemy;
        int* hp = (int*)(p + ENEMY_HP);
        if (hp && Ok(hp) && *hp > 200 && *hp < 50000) {
            static uintptr_t last = 0;
            if (p != last) {
                int oldHP = *hp;
                *hp = (int)(*hp * 2.5f);
                last = p;
            }
        }
    }
    if (orig_ApplyExtraDamage) orig_ApplyExtraDamage(enemy, damage);
}

// ========== 触摸优化 ==========
static void TouchFix(void) {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    [d setFloat:0.0f forKey:@"UnityTouchLatency"];
    [d setFloat:0.0f forKey:@"UnityTouchDelay"];
    [d synchronize];
    setenv("UNITY_INPUT_BUFFER_SIZE", "1", 1);
}

// ========== 安装 Hook ==========
static void InstallAllHooks(void) {
    if (g_hooks_done) return;
    g_hooks_done = YES;
    
    uint64_t base = GetBase();
    if (!base) return;
    
    void* a;
    a = (void*)(base + SHADOWDASH_RVA); if (Ok(a)) Hook(a, hk_ShadowDash, (void**)&orig_ShadowDash);
    a = (void*)(base + HERO_TAKEDAMAGE_RVA); if (Ok(a)) Hook(a, hk_TakeDamage, (void**)&orig_HeroTakeDamage);
    a = (void*)(base + ANIM_PLAY_RVA); if (Ok(a)) Hook(a, hk_Anim, (void**)&orig_AnimPlay);
    a = (void*)(base + ENEMY_APPLY_EXTRA_DAMAGE); if (Ok(a)) Hook(a, hk_ApplyExtraDamage, (void**)&orig_ApplyExtraDamage);
    
    TouchFix();
    NSLog(@"[Mod] All hooks installed (Boss HP 2.5x)");
}

// ========== ObjC Hook ==========
static void hk_becomeActive(id self, SEL _cmd, id arg) {
    if (orig_becomeActive) orig_becomeActive(self, _cmd, arg);
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        sleep(3);
        InstallAllHooks();
    });
}

static void InstallObjCHook(void) {
    Class c = objc_getClass("UnityAppController");
    if (!c) return;
    SEL s = sel_registerName("applicationDidBecomeActive:");
    Method m = class_getInstanceMethod(c, s);
    if (m) {
        orig_becomeActive = (void*)method_getImplementation(m);
        method_setImplementation(m, (IMP)hk_becomeActive);
    }
}

__attribute__((constructor))
static void Init(void) {
    InstallObjCHook();
    NSLog(@"[Mod] Hollow Knight Mod loaded (Full)");
}
