//
//  AiAssetTools.m
//  Amethyst
//
//  Air AI Agent 资源/网络工具（Phase 3b）实现：
//  - AiAssetSearchTool：Modrinth 搜索（search_mods / search_resourcepacks / search_shaders /
//    search_datapacks / search_modpacks / search_worlds）。
//  - AiAssetInstallTool：资源安装（install_mod / install_resourcepack / install_shader /
//    install_datapack）、下载页引导（install_game_version / install_loader）。
//  两类工具共享文件内私有 helper（AiAssetNetworkUtil / AiAssetInstaller）。
//  - 网络统一用 NSURLSession GET JSON（参考 AnnouncementService）。
//  - 文件下载统一走 PLDownloadClient，并注册到 DownloadTaskManager 以便进度页跟踪。
//  - 传统中括号语法 + ARC；结果一律调度回主线程回调。
//

#import "AiAssetTools.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "ModService.h"
#import "ShaderService.h"
#import "ResourcePackService.h"
#import "DataPackService.h"
#import "PLDownloadClient.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "AiSafetyManager.h"

/// 工具错误域与常见错误码
static NSString * const kAiAssetToolDomain = @"AiAssetTool";

#pragma mark - 文件内私有工具类：网络与路径

/// 网络 / 路径 / 安全文件名等通用 helper（文件内私有）
@interface AiAssetNetworkUtil : NSObject

/// GET JSON（对象或数组均可）；统一调度回主线程
+ (void)getJSONFromURL:(NSURL *)url completion:(void (^)(id _Nullable json, NSError * _Nullable error))completion;

/// 把文件名安全化（去掉会破坏路径的分隔符）
+ (NSString *)safeFileName:(NSString *)rawName;

/// 解析目标 profile（instance 参数优先，缺省取当前选中 profile）
+ (NSString *)resolveProfileName:(NSDictionary *)params;

/// 解析 profile 的 gameDir 绝对路径（相对路径相对 POJAV_GAME_DIR 展开）
+ (NSString *)resolveGameDirForProfile:(NSString *)profileName;

/// 判断某实例（gameDir）下是否已安装对应 MC 版本的 vanilla 本体
+ (BOOL)isGameVersionInstalled:(NSString *)mcVersion inGameDir:(NSString *)gameDir;

/// 向主线程 post ShowDownloadPage 通知（引导用户到内置下载页）
+ (void)postShowDownloadPage;

@end

#pragma mark - 文件内私有工具类：文件下载（PLDownloadClient + DownloadTaskManager）

@interface AiAssetInstaller : NSObject

/// 下载一个文件到目标目录，注册 DownloadTask 进度，完成回调主线程
+ (void)downloadFileFromURL:(NSURL *)url
                   filename:(NSString *)filename
                     folder:(NSString *)folder
                displayName:(NSString *)displayName
               resourceType:(NSString *)resourceType
                expectedSHA1:(nullable NSString *)expectedSHA1
                 completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion;

@end

@implementation AiAssetSearchTool {
    NSString *_internalName;
}

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

- (NSString *)name {
    return _internalName;
}

- (AiToolPermission)permission {
    return AiToolPermissionExternalNetwork;
}

- (NSString *)summary {
    if ([_internalName isEqualToString:@"search_resourcepacks"]) {
        return @"在 Modrinth 搜索资源包。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    if ([_internalName isEqualToString:@"search_shaders"]) {
        return @"在 Modrinth 搜索光影包（着色器）。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    if ([_internalName isEqualToString:@"search_datapacks"]) {
        return @"在 Modrinth 搜索数据包。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    if ([_internalName isEqualToString:@"search_modpacks"]) {
        return @"在 Modrinth 搜索整合包。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    if ([_internalName isEqualToString:@"search_worlds"]) {
        return @"在 Modrinth 搜索世界存档。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    // search_mods
    return @"在 Modrinth 搜索模组。"
           "\n参数：query（string，必填，搜索关键词）、facets（string，可选，mod/resourcepack/shaderpack/datapack/world/modpack，默认 mod）。"
           "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
}

#pragma mark - 执行

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    // facets 类型映射（固定或按 facets 参数）
    NSString *type = [self fixedType];
    NSString *query = [params[@"query"] isKindOfClass:[NSString class]] ? params[@"query"] : @"";
    if (query.length == 0) {
        NSError *err = [NSError errorWithDomain:kAiAssetToolDomain code:400
                                        userInfo:@{NSLocalizedDescriptionKey: @"缺少必填参数 query（搜索关键词）"}];
        completion(nil, err);
        return;
    }
    // search_mods 允许 facets 覆盖；其余工具 facets 固定
    if ([_internalName isEqualToString:@"search_mods"]) {
        NSString *f = [params[@"facets"] isKindOfClass:[NSString class]] ? params[@"facets"] : @"";
        if (f.length > 0) type = f;
    }

    NSString *encQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *facetsJSON = [NSString stringWithFormat:@"[[[\"project_type:%@\"]]]", type ?: @"mod"];
    NSString *encFacets = [facetsJSON stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:@"https://api.modrinth.com/v2/search?query=%@&facets=%@&limit=8", encQuery, encFacets];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        NSError *err = [NSError errorWithDomain:kAiAssetToolDomain code:500 userInfo:@{NSLocalizedDescriptionKey: @"搜索地址无效"}];
        completion(nil, err);
        return;
    }

    [AiAssetNetworkUtil getJSONFromURL:url completion:^(id _Nullable json, NSError * _Nullable error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSArray *hits = nil;
        if ([json isKindOfClass:[NSDictionary class]]) {
            hits = json[@"hits"];
        } else if ([json isKindOfClass:[NSArray class]]) {
            hits = json;
        }
        if (![hits isKindOfClass:[NSArray class]] || hits.count == 0) {
            completion(@"未找到相关项目", nil);
            return;
        }
        NSMutableArray *items = [NSMutableArray array];
        for (id hit in hits) {
            if (![hit isKindOfClass:[NSDictionary class]] || items.count >= 8) continue;
            NSString *title = hit[@"title"];
            NSString *desc = hit[@"description"];
            if (![desc isKindOfClass:[NSString class]]) desc = @"";
            // 描述截断 120 字符
            if (desc.length > 120) desc = [NSString stringWithFormat:@"%@…", [desc substringToIndex:120]];
            NSString *slug = hit[@"slug"];
            NSString *pid = hit[@"project_id"];
            NSNumber *downloads = hit[@"downloads"];
            if (![slug isKindOfClass:[NSString class]]) slug = @"";
            [items addObject:@{
                @"slug": slug,
                @"title": [title isKindOfClass:[NSString class]] ? title : @"",
                @"description": desc,
                @"downloads": ([downloads isKindOfClass:[NSNumber class]] ? downloads : @0),
                @"project_id": [pid isKindOfClass:[NSString class]] ? pid : @"",
            }];
        }
        if (items.count == 0) {
            completion(@"未找到相关项目", nil);
            return;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
        completion(data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]", nil);
    }];
}

/// 工具对应的固定 project_type（search_mods 默认 mod）
- (NSString *)fixedType {
    if ([_internalName isEqualToString:@"search_resourcepacks"]) return @"resourcepack";
    if ([_internalName isEqualToString:@"search_shaders"]) return @"shaderpack";
    if ([_internalName isEqualToString:@"search_datapacks"]) return @"datapack";
    if ([_internalName isEqualToString:@"search_modpacks"]) return @"modpack";
    if ([_internalName isEqualToString:@"search_worlds"]) return @"world";
    return @"mod";
}

@end

#pragma mark - AiAssetInstallTool

@implementation AiAssetInstallTool {
    NSString *_internalName;
}

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

- (NSString *)name {
    return _internalName;
}

- (AiToolPermission)permission {
    return AiToolPermissionControlledWrite;
}

- (NSString *)summary {
    if ([_internalName isEqualToString:@"install_resourcepack"]) {
        return @"从 Modrinth 下载并安装资源包到资源包目录。"
               "\n参数：slugOrId（string，必填，Modrinth 项目 slug 或 id）、versionId（string，可选，否则取 release 最新版本）、instance（string，可选，实例名）。"
               "\n返回安装结果说明。";
    }
    if ([_internalName isEqualToString:@"install_shader"]) {
        return @"从 Modrinth 下载并安装光影包到光影目录。"
               "\n参数：slugOrId（string，必填，Modrinth 项目 slug 或 id）、versionId（string，可选，否则取 release 最新版本）、instance（string，可选，实例名）。"
               "\n返回安装结果说明。";
    }
    if ([_internalName isEqualToString:@"install_datapack"]) {
        return @"从 Modrinth 下载并安装数据包到数据包目录。"
               "\n参数：slugOrId（string，必填，Modrinth 项目 slug 或 id）、versionId（string，可选，否则取 release 最新版本）、instance（string，可选，实例名）。"
               "\n返回安装结果说明。";
    }
    if ([_internalName isEqualToString:@"install_game_version"]) {
        return @"引导下载页以安装某个 Minecraft 版本本体（AI 不托管数百 MB 下载）。"
               "\n参数：versionId（string，可选，建议目标版本号）。"
               "\n行为：安全确认后为你打开内置版本下载页，请用户在页面中完成本体安装。";
    }
    if ([_internalName isEqualToString:@"install_loader"]) {
        return @"引导下载页以安装加载器（Fabric/Forge/NeoForge/Quilt/OptiFine）。"
               "\n参数：mcVersion（string，必填，目标 MC 版本）、loaderType（string，必填，fabric/forge/neoforge/quilt/optifine）、instance（string，可选，实例名）。"
               "\n行为：先检查 vanilla 本体是否已安装；未装则先引导装本体，已装则引导安装加载器。";
    }
    // install_mod
    return @"从 Modrinth 下载并安装模组到 mods 目录。"
           "\n参数：slugOrId（string，必填，Modrinth 项目 slug 或 id）、versionId（string，可选，否则取 release 最新版本）、instance（string，可选，实例名）。"
           "\n返回安装结果说明。";
}

#pragma mark - 执行

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    if ([_internalName isEqualToString:@"install_game_version"]) {
        [self performInstallGameVersion:params completion:completion];
        return;
    }
    if ([_internalName isEqualToString:@"install_loader"]) {
        [self performInstallLoader:params completion:completion];
        return;
    }
    [self performResourceInstall:params completion:completion];
}

#pragma mark - 资源安装（mod / resourcepack / shader / datapack）

/// 目标目录解析：根据工具名返回对应 Service 的 ensure 目录
- (nullable NSString *)resolvedFolderForParams:(NSDictionary *)params {
    NSString *profile = [AiAssetNetworkUtil resolveProfileName:params];
    NSError *err = nil;
    if ([_internalName isEqualToString:@"install_mod"]) {
        return [[ModService sharedService] ensureModsFolderForProfile:profile error:&err];
    }
    if ([_internalName isEqualToString:@"install_resourcepack"]) {
        return [[ResourcePackService sharedService] ensureResourcePacksFolderForProfile:profile error:&err];
    }
    if ([_internalName isEqualToString:@"install_shader"]) {
        return [[ShaderService sharedService] ensureShadersFolderForProfile:profile error:&err];
    }
    if ([_internalName isEqualToString:@"install_datapack"]) {
        return [[DataPackService sharedService] ensureDataPacksFolderForProfile:profile error:&err];
    }
    return nil;
}

/// Install 工具对应的资源类型（注册 DownloadTask 用）
- (NSString *)resourceTypeForTool {
    if ([_internalName isEqualToString:@"install_mod"]) return DownloadTaskResourceTypeMod;
    if ([_internalName isEqualToString:@"install_resourcepack"]) return DownloadTaskResourceTypeResourcePack;
    if ([_internalName isEqualToString:@"install_shader"]) return DownloadTaskResourceTypeShader;
    if ([_internalName isEqualToString:@"install_datapack"]) return DownloadTaskResourceTypeDataPack;
    return DownloadTaskResourceTypeMod;
}

- (void)performResourceInstall:(NSDictionary *)params
                    completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    NSString *slugOrId = [params[@"slugOrId"] isKindOfClass:[NSString class]] ? params[@"slugOrId"] : @"";
    if (slugOrId.length == 0) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400
                                        userInfo:@{NSLocalizedDescriptionKey: @"缺少必填参数 slugOrId"}]);
        return;
    }

    // 目标目录
    NSString *folder = [self resolvedFolderForParams:params];
    if (folder.length == 0) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:500 userInfo:@{NSLocalizedDescriptionKey: @"无法确定安装目录"}]);
        return;
    }
    NSString *versionId = [params[@"versionId"] isKindOfClass:[NSString class]] ? params[@"versionId"] : @"";

    NSString *encSlug = [slugOrId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    // 1. 项目信息（取项目名做 displayName）
    NSString *projectURLStr = [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@", encSlug];
    NSURL *projectURL = [NSURL URLWithString:projectURLStr];
    if (!projectURL) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400 userInfo:@{NSLocalizedDescriptionKey: @"无效的项目标识"}]);
        return;
    }
    [AiAssetNetworkUtil getJSONFromURL:projectURL completion:^(id _Nullable projectJSON, NSError * _Nullable projectError) {
        if (projectError) {
            completion(nil, projectError);
            return;
        }
        NSString *projectTitle = @"";
        if ([projectJSON isKindOfClass:[NSDictionary class]] && [projectJSON[@"title"] isKindOfClass:[NSString class]]) {
            projectTitle = projectJSON[@"title"];
        }
        [self fetchVersionsForSlug:encSlug versionId:versionId completion:^(NSString * _Nullable filename, NSURL * _Nullable fileURL, NSString * _Nullable sha1, NSError * _Nullable verError) {
            if (verError) {
                completion(nil, verError);
                return;
            }
            NSString *displayName = projectTitle.length > 0 ? projectTitle : filename;
            NSString *safeFile = [AiAssetNetworkUtil safeFileName:filename];
            [AiAssetInstaller downloadFileFromURL:fileURL
                                         filename:safeFile
                                           folder:folder
                                      displayName:displayName
                                     resourceType:[self resourceTypeForTool]
                                      expectedSHA1:sha1
                                       completion:completion];
        }];
    }];
}

/// 拉取项目版本列表并选择目标版本文件（可选匹配 versionId，否则选 release 最新）
- (void)fetchVersionsForSlug:(NSString *)encSlug
                   versionId:(NSString *)versionId
                  completion:(void (^)(NSString * _Nullable filename, NSURL * _Nullable fileURL, NSString * _Nullable sha1, NSError * _Nullable error))completion {
    NSString *urlStr = [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@/version?featured=true", encSlug];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:500 userInfo:@{NSLocalizedDescriptionKey: @"版本列表地址无效"}]);
        return;
    }
    [AiAssetNetworkUtil getJSONFromURL:url completion:^(id _Nullable json, NSError * _Nullable error) {
        if (error) {
            completion(nil, nil, nil, error);
            return;
        }
        NSArray *versions = [json isKindOfClass:[NSArray class]] ? json : nil;
        if (versions.count == 0) {
            completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:404 userInfo:@{NSLocalizedDescriptionKey: @"该项目暂无可用版本"}]);
            return;
        }
        // 选择版本
        NSDictionary *chosen = nil;
        if (versionId.length > 0) {
            for (id v in versions) {
                if ([v isKindOfClass:[NSDictionary class]] && [v[@"id"] isEqualToString:versionId]) { chosen = v; break; }
            }
            if (!chosen) {
                completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:404
                                                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未找到版本 %@", versionId]}]);
                return;
            }
        } else {
            // 优先 release / latest，回退首个
            for (id v in versions) {
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                id vt = v[@"version_type"];
                if ([vt isKindOfClass:[NSString class]] && [vt isEqualToString:@"release"]) { chosen = v; break; }
            }
            if (!chosen) chosen = [versions firstObject];
        }
        NSArray *files = [chosen isKindOfClass:[NSDictionary class]] ? chosen[@"files"] : nil;
        NSDictionary *file = ([files isKindOfClass:[NSArray class]] && files.count > 0) ? files[0] : nil;
        if (![file isKindOfClass:[NSDictionary class]]) {
            completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:404 userInfo:@{NSLocalizedDescriptionKey: @"所选版本无可用文件"}]);
            return;
        }
        NSString *fileURLStr = file[@"url"];
        NSString *filename = file[@"filename"];
        NSString *sha1 = nil;
        NSDictionary *hashes = file[@"hashes"];
        if ([hashes isKindOfClass:[NSDictionary class]] && [hashes[@"sha1"] isKindOfClass:[NSString class]]) {
            sha1 = hashes[@"sha1"];
        }
        NSURL *fileURL = [NSURL URLWithString:[fileURLStr isKindOfClass:[NSString class]] ? fileURLStr : @""];
        if (![filename isKindOfClass:[NSString class]]) filename = @"download";
        if (!fileURL) {
            completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:404 userInfo:@{NSLocalizedDescriptionKey: @"下载地址无效"}]);
            return;
        }
        completion(filename, fileURL, sha1, nil);
    }];
}

#pragma mark - install_game_version（引导下载页）

- (void)performInstallGameVersion:(NSDictionary *)params
                       completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    NSString *versionId = [params[@"versionId"] isKindOfClass:[NSString class]] ? params[@"versionId"] : @"";

    void (^openPage)(void) = ^{
        // 打开下载页引导用户完成本体安装
        [AiAssetNetworkUtil postShowDownloadPage];
        NSString *hint = versionId.length > 0 ? versionId : @"目标版本";
        completion([NSString stringWithFormat:@"已为你打开版本下载页，请选择 %@ 完成安装；安装 MC 本体后我才能继续安装加载器/模组。", hint], nil);
    };

    // 确认由 AiAgent 统一安全门处理（ControlledWrite 在 Safe/Ask 下已弹确认），此处不再重复弹窗
    openPage();
}

#pragma mark - install_loader（检查本体并引导加载器）

- (void)performInstallLoader:(NSDictionary *)params
                  completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    NSString *mcVersion = [params[@"mcVersion"] isKindOfClass:[NSString class]] ? params[@"mcVersion"] : @"";
    NSString *loaderType = [params[@"loaderType"] isKindOfClass:[NSString class]] ? [params[@"loaderType"] lowercaseString] : @"";
    if (mcVersion.length == 0) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400 userInfo:@{NSLocalizedDescriptionKey: @"缺少必填参数 mcVersion"}]);
        return;
    }
    NSSet *validLoaders = [NSSet setWithObjects:@"fabric", @"forge", @"neoforge", @"quilt", @"optifine", nil];
    if (![validLoaders containsObject:loaderType]) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400
                                        userInfo:@{NSLocalizedDescriptionKey: @"loaderType 必须为 fabric / forge / neoforge / quilt / optifine 之一"}]);
        return;
    }
    NSString *profile = [AiAssetNetworkUtil resolveProfileName:params];
    NSString *gameDir = [AiAssetNetworkUtil resolveGameDirForProfile:profile];
    BOOL installed = [AiAssetNetworkUtil isGameVersionInstalled:mcVersion inGameDir:gameDir];

    [AiAssetNetworkUtil postShowDownloadPage];
    if (!installed) {
        completion([NSString stringWithFormat:@"MC %@ 本体尚未安装。必须先安装对应版本的 MC 本体（紫色规则），已为你打开下载页，请先完成本体安装，再来让我装 %@。", mcVersion, loaderType], nil);
    } else {
        completion([NSString stringWithFormat:@"MC %@ 已就绪，已为你打开下载页，请在页面中安装 %@ 加载器（通常选择版本时点选对应加载器）。", mcVersion, loaderType], nil);
    }
}

@end

#pragma mark - AiAssetNetworkUtil 实现

@implementation AiAssetNetworkUtil

+ (void)getJSONFromURL:(NSURL *)url completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400 userInfo:@{NSLocalizedDescriptionKey: @"URL 为空"}]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"Air/1.0 (iOS)" forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = 20.0;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) {
                if (completion) completion(nil, error ?: [NSError errorWithDomain:kAiAssetToolDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"网络请求失败"}]);
                return;
            }
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (status < 200 || status >= 300) {
                NSString *msg = (status == 404) ? @"资源不存在（404）" : [NSString stringWithFormat:@"请求失败（HTTP %ld）", (long)status];
                if (completion) completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:status userInfo:@{NSLocalizedDescriptionKey: msg}]);
                return;
            }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (completion) completion(json, nil);
        });
    }];
    [task resume];
}

+ (NSString *)safeFileName:(NSString *)rawName {
    if (rawName.length == 0) return @"download";
    NSMutableCharacterSet *bad = [NSMutableCharacterSet characterSetWithCharactersInString:@"/\\:"];
    NSArray *parts = [rawName componentsSeparatedByCharactersInSet:bad];
    return [parts componentsJoinedByString:@"_"];
}

+ (NSString *)resolveProfileName:(NSDictionary *)params {
    NSString *instance = [params[@"instance"] isKindOfClass:[NSString class]] ? params[@"instance"] : @"";
    if (instance.length > 0) return instance;
    NSString *name = [[PLProfiles current] selectedProfileName];
    return (name.length > 0) ? name : @"default";
}

+ (NSString *)resolveGameDirForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    @try {
        NSDictionary *profiles = [PLProfiles current].profiles;
        NSDictionary *prof = [profiles isKindOfClass:[NSDictionary class]] ? profiles[profile] : nil;
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0) {
                if ([gameDir isEqualToString:@"."]) {
                    const char *env = getenv("POJAV_GAME_DIR");
                    return env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
                }
                if ([gameDir isAbsolutePath]) return gameDir;
                const char *env = getenv("POJAV_GAME_DIR");
                NSString *base = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
                NSString *clean = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
                return [base stringByAppendingPathComponent:clean];
            }
        }
    } @catch (NSException *ex) {
        // ignore
    }
    const char *root = getenv("POJAV_GAME_DIR");
    if (root && strlen(root) > 0) return [NSString stringWithUTF8String:root];
    return NSHomeDirectory();
}

+ (BOOL)isGameVersionInstalled:(NSString *)mcVersion inGameDir:(NSString *)gameDir {
    if (mcVersion.length == 0 || gameDir.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    // 1. <gameDir>/versions/<mcVersion>/（目录含 .json）
    NSString *versionsDir = [gameDir stringByAppendingPathComponent:@"versions"];
    NSString *verPath = [versionsDir stringByAppendingPathComponent:mcVersion];
    if ([fm fileExistsAtPath:verPath isDirectory:&isDir] && isDir) return YES;
    if ([fm fileExistsAtPath:[verPath stringByAppendingPathExtension:@"json"]]) return YES;
    // 2. <gameDir>/<mcVersion>.json
    if ([fm fileExistsAtPath:[gameDir stringByAppendingPathComponent:[mcVersion stringByAppendingPathExtension:@"json"]]]) return YES;
    return NO;
}

+ (void)postShowDownloadPage {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
    });
}

@end

#pragma mark - AiAssetInstaller 实现

@implementation AiAssetInstaller

+ (void)downloadFileFromURL:(NSURL *)url
                   filename:(NSString *)filename
                     folder:(NSString *)folder
                displayName:(NSString *)displayName
               resourceType:(NSString *)resourceType
                expectedSHA1:(nullable NSString *)expectedSHA1
                 completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!url || folder.length == 0 || filename.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400 userInfo:@{NSLocalizedDescriptionKey: @"下载参数不完整"}]);
        });
        return;
    }

    NSString *resourceName = filename;
    NSString *dispName = displayName.length > 0 ? displayName : filename;
    DownloadTaskItem *task = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:resourceType
                        resourceName:resourceName
                         displayName:dispName
                      downloadSource:@"Modrinth"
                             rawTask:nil
                      supportsResume:YES
                             iconURL:nil];
    task.downloadURL = url.absoluteString;
    [[DownloadTaskManager sharedManager] setTaskWithId:task.taskId state:DownloadTaskStateDownloading];

    PLDownloadRequest *request = [[PLDownloadRequest alloc] init];
    request.candidateURLs = @[url];
    if (expectedSHA1.length > 0) request.expectedSHA1 = expectedSHA1;
    request.destinationPath = [folder stringByAppendingPathComponent:filename];
    request.taskIdentifier = task.taskId;
    request.allowZipFallbackCheck = YES;

    __block int64_t downloadedBytes = 0;
    __block NSTimeInterval lastReport = 0;
    __block int64_t reportedTotal = -1;

    [[PLDownloadClient sharedClient] startRequest:request
        progress:^(int64_t deltaBytes, int64_t totalExpectedBytes) {
            // 进度回调节流 ≤ 200ms
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if ((now - lastReport) < 0.2) return;
            lastReport = now;
            downloadedBytes += deltaBytes;
            if (totalExpectedBytes > 0) reportedTotal = totalExpectedBytes;
            double progress = -1;
            if (reportedTotal > 0) progress = (double)downloadedBytes / (double)reportedTotal;
            [[DownloadTaskManager sharedManager] updateTaskWithId:task.taskId
                                                         progress:progress
                                                       totalBytes:reportedTotal
                                                  downloadedBytes:downloadedBytes];
        }
        speed:^(int64_t bytesPerSecond) {
            [[DownloadTaskManager sharedManager] updateTaskWithId:task.taskId
                                                            speed:(double)bytesPerSecond
                                           estimatedTimeRemaining:-1];
        }
        completion:^(BOOL success, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!success) {
                    [[DownloadTaskManager sharedManager] setTaskWithId:task.taskId
                                                      completedWithError:error ?: [NSError errorWithDomain:kAiAssetToolDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"下载失败"}]];
                    if (completion) completion(nil, error ?: [NSError errorWithDomain:kAiAssetToolDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"下载失败"}]);
                    return;
                }
                [[DownloadTaskManager sharedManager] setTaskWithId:task.taskId completedWithError:nil];
                NSString *result = [NSString stringWithFormat:@"已安装 %@ 到 %@（%@）", dispName, [folder lastPathComponent], filename];
                if (completion) completion(result, nil);
            });
        }];
}

@end