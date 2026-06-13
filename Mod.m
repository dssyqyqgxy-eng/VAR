// Mod.m - 空洞骑士 GTE 版全功能 Mod（最终版 + 日志）
// 功能：攻击冷却0.15 + 黑冲无冷却无粒子 + 只加速攻击动画1.8x + Boss血量2.5x

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <pthread.h>
#import <sys/mman.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <os/log.h>

// ========== 精确 RVA（相对于 UnityFramework） ==========
#define HERO_TAKEDAMAGE_RVA            0x102614C
#define HERO_SHADOWDASH_RVA            0x102D4DC
#define HERO_DOATTACK_RVA              0x102FF1C
#define ANIM_PLAY_FPS_RVA              0x1314A7C
#define ENEMY_APPLY_EXTRA_DAMAGE_RVA   0x1022A58

// ========== 字段偏移 ==========
#define ATK_OFF                0x214
#define HAS_SHD                0x15B
#define CAN_SHD                0x124
#define SHD_COOLDOWN           0x80
#define SHD_TIME               0x7C
#define SHD_TIMER              0x20C
#define SHD_RECHARGE_PREFAB    0x398
#define ENEMY_HP               0xE8

// ========== 函数指针 ==========
typedef void (*VoidFunc)(void);
typedef void (*TakeDamageFunc)(void*, void*, int, int, int);
typedef void (*AnimPlayFunc)(void*, void*, float, float);
typedef void (*ApplyExtraDamageFunc)(void*, int);

// ========== 全局 ==========
static VoidFunc              orig_ShadowDash       = NULL;
static TakeDamageFunc        orig_HeroTakeDamage   = NULL;
static VoidFunc              orig_DoAttack         = NULL;
static AnimPlayFunc          orig_AnimPlay         = NULL;
static ApplyExtraDamageFunc  orig_ApplyExtraDamage = NULL;
static void*                 g_hero                = NULL;
static pthread_mutex_t       g_lock                = PTHREAD_MUTEX_INITIALIZER;
static BOOL                  g_hooks_done          = NO;
static BOOL                  g_in_attack           = NO;
static IMP                   g_orig_becomeActive   = NULL;

// ========== 获取 UnityFramework 基址 ==========
static uint64_t GetBase(void) {
    for (int i = 0; i < _dyld_image_count(); i++) {
        const char* name = _dyld_get_image_name(i);
        if (strstr(name, "UnityFramework.framework/UnityFramework")) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
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
    if (!Ok(tgt)) {
        os_log(OS_LOG_DEFAULT, "[HKMod] Hook skipped: invalid target %p", tgt);
        return;
    }
    void* tr = mmap(NULL, 32, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0);
    if (tr == MAP_FAILED) {
        os_log(OS_LOG_DEFAULT, "[HKMod] Hook failed: mmap error");
        return;
    }
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
    os_log(OS_LOG_DEFAULT, "[HKMod] Hook installed at %p", tgt);
}

// ========== 修改玩家属性 ==========
static void ModHero(void* h) {
    if (!Ok(h)) return;
    uintptr_t p = (uintptr_t)h;
    float* atk = (float*)(p+ATK_OFF);
    bool*  hs  = (bool*)(p+HAS_SHD);
    bool*  cs  = (bool*)(p+CAN_SHD);
    float* scd = (float*)(p+SHD_COOLDOWN);
    float* stm = (float*)(p+SHD_TIMER);
    float* sti = (float*)(p+SHD_TIME);
    void** rp  = (void**)(p+SHD_RECHARGE_PREFAB);
    if (Ok(atk)) *atk = 0.15f;
    if (Ok(hs))  *hs  = true;
    if (Ok(cs))  *cs  = true;
    if (Ok(scd)) *scd = 0.0f;
    if (Ok(stm)) *stm = 0.0f;
    if (Ok(sti)) *sti = 0.0f;
    if (Ok(rp))  *rp  = NULL;
}

// ========== Boss 血量 ==========
static void ModBossHP(void* enemy) {
    if (!Ok(enemy)) return;
    int* hp = (int*)((uintptr_t)enemy + ENEMY_HP);
    if (Ok(hp) && *hp > 200 && *hp < 50000) {
        static uintptr_t last = 0;
        if ((uintptr_t)enemy != last) {
            *hp = (int)(*hp * 2.5f);
            last = (uintptr_t)enemy;
        }
    }
}

// ========== Hook 实现 ==========
static void hk_ShadowDash(void) {
    pthread_mutex_lock(&g_lock);
    ModHero(g_hero);
    pthread_mutex_unlock(&g_lock);
    if (orig_ShadowDash) orig_ShadowDash();
}

static void hk_TakeDamage(void* self, void* go, int side, int amount, int hazard) {
    pthread_mutex_lock(&g_lock);
    g_hero = self;
    ModHero(self);
    pthread_mutex_unlock(&g_lock);
    if (orig_HeroTakeDamage) orig_HeroTakeDamage(self, go, side, amount, hazard);
}

static void hk_DoAttack(void) {
    g_in_attack = YES;
    if (orig_DoAttack) orig_DoAttack();
    g_in_attack = NO;
}

static void hk_AnimPlay(void* anim, void* clip, float startTime, float fps) {
    if (orig_AnimPlay) orig_AnimPlay(anim, clip, startTime, g_in_attack ? fps * 1.8f : fps);
}

static void hk_ApplyExtraDamage(void* enemy, int damage) {
    ModBossHP(enemy);
    if (orig_ApplyExtraDamage) orig_ApplyExtraDamage(enemy, damage);
}

// ========== 安装 Hook ==========
static void InstallAllHooks(void) {
    if (g_hooks_done) return;
    g_hooks_done = YES;
    
    uint64_t base = GetBase();
    os_log(OS_LOG_DEFAULT, "[HKMod] UnityFramework base: 0x%llx", base);
    
    if (!base) {
        os_log(OS_LOG_DEFAULT, "[HKMod] ERROR: base is 0");
        return;
    }
    
    void* addrs[5];
    uint64_t rvas[] = {HERO_SHADOWDASH_RVA, HERO_TAKEDAMAGE_RVA, HERO_DOATTACK_RVA, ANIM_PLAY_FPS_RVA, ENEMY_APPLY_EXTRA_DAMAGE_RVA};
    const char* names[] = {"ShadowDash", "TakeDamage", "DoAttack", "AnimPlay", "ApplyExtraDamage"};
    
    for (int i = 0; i < 5; i++) {
        addrs[i] = (void*)(base + rvas[i]);
        os_log(OS_LOG_DEFAULT, "[HKMod] %s: %p (valid=%d)", names[i], addrs[i], Ok(addrs[i]));
    }
    
    if (Ok(addrs[0])) Hook(addrs[0], hk_ShadowDash, (void**)&orig_ShadowDash);
    if (Ok(addrs[1])) Hook(addrs[1], hk_TakeDamage, (void**)&orig_HeroTakeDamage);
    if (Ok(addrs[2])) Hook(addrs[2], hk_DoAttack, (void**)&orig_DoAttack);
    if (Ok(addrs[3])) Hook(addrs[3], hk_AnimPlay, (void**)&orig_AnimPlay);
    if (Ok(addrs[4])) Hook(addrs[4], hk_ApplyExtraDamage, (void**)&orig_ApplyExtraDamage);
    
    os_log(OS_LOG_DEFAULT, "[HKMod] Hooks installed: SD=%d TD=%d DA=%d AP=%d AED=%d",
           orig_ShadowDash != NULL,
           orig_HeroTakeDamage != NULL,
           orig_DoAttack != NULL,
           orig_AnimPlay != NULL,
           orig_ApplyExtraDamage != NULL);
}

// ========== 注入时机 ==========
static void hk_becomeActive(id self, SEL _cmd, id arg) {
    if (g_orig_becomeActive) ((void(*)(id,SEL,id))g_orig_becomeActive)(self, _cmd, arg);
    os_log(OS_LOG_DEFAULT, "[HKMod] applicationDidBecomeActive triggered");
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_global_queue(0,0), ^{
            InstallAllHooks();
        });
    });
}

static void InstallObjCHook(void) {
    Class c = objc_getClass("UnityAppController");
    if (!c) {
        os_log(OS_LOG_DEFAULT, "[HKMod] UnityAppController not found");
        return;
    }
    SEL s = sel_registerName("applicationDidBecomeActive:");
    Method m = class_getInstanceMethod(c, s);
    if (m) {
        g_orig_becomeActive = method_getImplementation(m);
        method_setImplementation(m, (IMP)hk_becomeActive);
        os_log(OS_LOG_DEFAULT, "[HKMod] ObjC hook installed");
    }
}

// ========== 入口 ==========
__attribute__((constructor))
static void Init(void) {
    os_log(OS_LOG_DEFAULT, "[HKMod] dylib loaded | iOS %@ | %@",
           [[UIDevice currentDevice] systemVersion],
           [[UIDevice currentDevice] model]);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        uint64_t base = GetBase();
        os_log(OS_LOG_DEFAULT, "[HKMod] UnityFramework base: 0x%llx", base);
        for (int i = 0; i < _dyld_image_count(); i++) {
            const char* name = _dyld_get_image_name(i);
            if (strstr(name, "UnityFramework") || strstr(name, "HollowKnight")) {
                os_log(OS_LOG_DEFAULT, "[HKMod] %s slide=0x%llx", name, _dyld_get_image_vmaddr_slide(i));
            }
        }
    });
    
    InstallObjCHook();
}
