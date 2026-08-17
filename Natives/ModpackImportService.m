//
//  ModpackImportService.m
//  Amethyst
//
//  Modpack import service implementation
//
//  参照 FCL (Fold Craft Launcher) 的整合包导入流程重写:
//  1. 正确解析 Modrinth (.mrpack) 和 CurseForge (manifest.json) 两种格式
//  2. 解压 overrides/client-overrides 到 gameDir (而非 modpackDir 根目录)
//  3. 下载 manifest/files 列出的所有 mod 到 gameDir/mods
//  4. 对 Fabric/Quilt 整合包自动拉取 loader profile json 写入版本目录
//  5. 对 Forge/NeoForge 整合包下载 installer.jar 并调用直装器写入 modpack gameDir
//  6. gameDir 使用相对路径 (./custom_gamedir/<id>) 与启动器 POJAV_GAME_DIR 对齐
//  7. 写完整 profile (含 gameDir、lastVersionId、icon)
//

#import "ModpackImportService.h"
#import "installer/FabricUtils.h"
#import "installer/modpack/ModpackUtils.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "PLPreferences.h"
#import "UnzipKit.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "PLDownloadClient.h"
#import "PLMirrorCenter.h"

static NSString * const kImportedModpacksKey = @"ImportedModpacks";

@interface ModpackImportService ()
/// 整合包工作区根目录: <POJAV_GAME_DIR>/custom_gamedir
@property (nonatomic, strong) NSString *customGameDir;
/// 阶段5修复（参照 FCL DownloadList）：跟踪本次导入过程中下载失败的文件，便于上层向用户报告
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *failedFilesInternal;
/// Phase 3（Task 3.2）：跟踪本次导入过程中因 404/资源不存在被跳过的文件（警告，非失败）
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *skippedFilesInternal;

// 前向声明：将 modpackInfo 中的 iconBase64 解析为可用的文件 URL 字符串
- (nullable NSString *)resolveIconURLFromModpackInfo:(NSDictionary *)modpackInfo;
@end

@implementation ModpackImportService

- (instancetype)init {
    self = [super init];
    if (self) {
        // 整合包目录直接用 POJAV_GAME_DIR 下的 custom_gamedir，gameDir 字段写相对路径
        // 这样启动器读取 profile 时会拼成 <POJAV_GAME_DIR>/custom_gamedir/<id>
        const char *gameDirEnv = getenv("POJAV_GAME_DIR");
        self.customGameDir = [@(gameDirEnv ?: ".") stringByAppendingPathComponent:@"custom_gamedir"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:self.customGameDir]) {
            [fm createDirectoryAtPath:self.customGameDir withIntermediateDirectories:YES attributes:nil error:nil];
        }

        // Phase 3：文件下载统一交给 PLDownloadClient（镜像重试/SHA1 校验/断点续传由其内部处理），
        // 不再自建 NSURLSession + delegate + 信号量字典的同步下载机制。
        _failedFilesInternal = [NSMutableArray array];
        _skippedFilesInternal = [NSMutableArray array];
        _cancelled = NO;
    }
    return self;
}

/// 阶段5修复：公共只读访问器，返回不可变拷贝防止外部修改
- (NSArray<NSDictionary *> *)failedFiles {
    @synchronized(self) {
        return [self.failedFilesInternal copy];
    }
}

/// Phase 3（Task 3.2）：下载失败文件只读访问器（仅 modrinth/curseforge 的 mod 文件条目），
/// 供 UI 阶段展示与单独重试；version（加载器/游戏文件）条目仍走 failedFiles。
- (NSArray<NSDictionary *> *)failedDownloadFiles {
    @synchronized(self) {
        NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
        for (NSDictionary *f in self.failedFilesInternal) {
            NSString *fmt = f[@"format"];
            if ([fmt isEqualToString:@"modrinth"] || [fmt isEqualToString:@"curseforge"]) {
                [result addObject:f];
            }
        }
        return [result copy];
    }
}

/// Phase 3（Task 3.2）：404/资源不存在被跳过的文件只读访问器（警告，非失败）
- (NSArray<NSDictionary *> *)skippedDownloadFiles {
    @synchronized(self) {
        return [self.skippedFilesInternal copy];
    }
}

- (void)resetCancelState {
    @synchronized(self) {
        _cancelled = NO;
    }
}

/// 内部使用：抛出取消错误
- (BOOL)checkCancelledWithError:(NSError **)error {
    @synchronized(self) {
        if (_cancelled) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackImportError"
                                             code:9999
                                         userInfo:@{NSLocalizedDescriptionKey: @"导入已取消"}];
            }
            return YES;
        }
    }
    return NO;
}

#pragma mark - Helpers

/// 将 modpackInfo 中的 iconBase64 字段解析为可用的图标 URL。
/// modrinth.index.json 中 iconBase64 是 base64 编码的图片数据（如 "data:image/png;base64,...." 或纯 base64 字符串），
/// 不能直接作为 URL 使用。该方法将其解码为 UIImage，保存到临时文件，返回文件 URL 字符串。
/// 如果解析失败或无图标，返回 nil（调用方使用默认图标）。
- (nullable NSString *)resolveIconURLFromModpackInfo:(NSDictionary *)modpackInfo {
    NSString *iconBase64 = modpackInfo[@"iconBase64"];
    if (!iconBase64 || iconBase64.length == 0) return nil;

    // 去除可能的 data URI 前缀（如 "data:image/png;base64,"）
    NSString *base64String = iconBase64;
    NSString *prefix = @"base64,";
    NSRange prefixRange = [iconBase64 rangeOfString:prefix];
    if (prefixRange.location != NSNotFound) {
        base64String = [iconBase64 substringFromIndex:prefixRange.location + prefixRange.length];
    }

    // 解码 base64
    NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64String
                                                             options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!imageData || imageData.length == 0) return nil;

    // 保存到临时文件
    NSString *tempDir = NSTemporaryDirectory();
    NSString *iconFileName = [NSString stringWithFormat:@"modpack_icon_%@.png",
                              modpackInfo[@"id"] ?: modpackInfo[@"name"] ?: @"unknown"];
    NSString *iconPath = [tempDir stringByAppendingPathComponent:iconFileName];
    NSError *writeError = nil;
    if ([imageData writeToFile:iconPath options:NSDataWritingAtomic error:&writeError]) {
        // 返回文件 URL 字符串（AFNetworking 的 setImageWithURL: 支持文件 URL）
        NSURL *fileURL = [NSURL fileURLWithPath:iconPath];
        return fileURL.absoluteString;
    }
    return nil;
}

/// 将 NSDate 转为 ISO8601 字符串，确保 JSON 序列化安全
- (NSString *)iso8601StringFromDate:(NSDate *)date {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    });
    return [formatter stringFromDate:date];
}

/// 给定 modpack id，返回 gameDir 的绝对路径 (用于本地文件操作)
- (NSString *)absoluteGameDirForModpackId:(NSString *)modpackId {
    return [self.customGameDir stringByAppendingPathComponent:modpackId];
}

/// 给定 modpack id，返回 gameDir 的相对路径 (写入 profile 的 gameDir 字段)
- (NSString *)relativeGameDirForModpackId:(NSString *)modpackId {
    return [NSString stringWithFormat:@"./custom_gamedir/%@", modpackId];
}

/// 把 Modrinth dependencies 解析成 loader 信息
- (void)resolveModrinthDependencies:(NSDictionary *)dependencies
                            loader:(NSString **)outLoader
                     loaderVersion:(NSString **)outLoaderVersion
                    minecraftVer:(NSString **)outMcVersion {
    if (outMcVersion) *outMcVersion = dependencies[@"minecraft"];
    if (dependencies[@"forge"]) {
        if (outLoader) *outLoader = @"Forge";
        if (outLoaderVersion) *outLoaderVersion = dependencies[@"forge"];
    } else if (dependencies[@"neoforge"]) {
        if (outLoader) *outLoader = @"NeoForge";
        if (outLoaderVersion) *outLoaderVersion = dependencies[@"neoforge"];
    } else if (dependencies[@"fabric-loader"]) {
        if (outLoader) *outLoader = @"Fabric";
        if (outLoaderVersion) *outLoaderVersion = dependencies[@"fabric-loader"];
    } else if (dependencies[@"quilt-loader"]) {
        if (outLoader) *outLoader = @"Quilt";
        if (outLoaderVersion) *outLoaderVersion = dependencies[@"quilt-loader"];
    } else {
        if (outLoader) *outLoader = @"Vanilla";
        if (outLoaderVersion) *outLoaderVersion = @"";
    }
}

/// 把 CurseForge manifest.modLoaders 解析成 loader 信息
- (void)resolveCurseForgeLoader:(NSArray *)modLoaders
                        loader:(NSString **)outLoader
                 loaderVersion:(NSString **)outLoaderVersion {
    if (outLoader) *outLoader = @"Vanilla";
    if (outLoaderVersion) *outLoaderVersion = @"";
    if (modLoaders.count == 0) return;
    NSDictionary *loaderInfo = modLoaders.firstObject;
    NSString *loaderId = loaderInfo[@"id"];
    if ([loaderId hasPrefix:@"forge-"]) {
        if (outLoader) *outLoader = @"Forge";
        if (outLoaderVersion) *outLoaderVersion = [loaderId substringFromIndex:6];
    } else if ([loaderId hasPrefix:@"neoforge-"]) {
        if (outLoader) *outLoader = @"NeoForge";
        if (outLoaderVersion) *outLoaderVersion = [loaderId substringFromIndex:9];
    } else if ([loaderId hasPrefix:@"fabric-"]) {
        if (outLoader) *outLoader = @"Fabric";
        if (outLoaderVersion) *outLoaderVersion = [loaderId substringFromIndex:7];
    } else if ([loaderId hasPrefix:@"quilt-"]) {
        if (outLoader) *outLoader = @"Quilt";
        if (outLoaderVersion) *outLoaderVersion = [loaderId substringFromIndex:6];
    }
}

#pragma mark - Parse Modpack

- (nullable NSDictionary *)parseModpackAtURL:(NSURL *)fileURL error:(NSError **)error {
    NSString *filePath = fileURL.path;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"文件不存在"}];
        }
        return nil;
    }

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:filePath error:&archiveError];
    if (archiveError || !archive) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法打开压缩文件"}];
        }
        return nil;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&archiveError];
    if (indexData) {
        return [self parseModrinthModpack:archive indexData:indexData filePath:filePath error:error];
    }

    // 关键修复（多启动器兼容）：MMC (MultiMC / Prism Launcher) 整合包检测
    // mmc-pack.json 标志文件包含 components 数组，每个 component 有 uid（net.minecraft / net.fabricmc.fabric-loader 等）
    // 必须在 manifest.json (CurseForge) 之前检测，因为某些 MMC 整合包可能也含有 manifest.json
    NSData *mmcPackData = [archive extractDataFromFile:@"mmc-pack.json" error:&archiveError];
    if (mmcPackData) {
        NSLog(@"[ModpackImport] Detected MMC (MultiMC/Prism) modpack");
        return [self parseMMCPack:archive mmcPackData:mmcPackData filePath:filePath error:error];
    }

    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&archiveError];
    if (manifestData) {
        return [self parseManifestModpack:archive manifestData:manifestData filePath:filePath error:error];
    }

    // 关键修复（多启动器兼容）：添加 Plain ZIP 整合包支持
    // Plain ZIP 是 HMCL/FCL/PojavLauncher 等启动器导出的"纯 .minecraft 目录结构"整合包：
    //   - 无 modrinth.index.json 和 manifest.json
    //   - zip 根目录直接包含 mods/、config/、versions/、options.txt 等 .minecraft 文件
    //   - 也兼容 .minecraft/ 前缀的 zip（HMCL 导出格式之一）
    // 此格式无 mod 下载清单，所有文件直接从 zip 解压，loader 需用户后续手动安装。
    if ([self isPlainZipModpack:archive]) {
        NSLog(@"[ModpackImport] Detected Plain ZIP modpack (no manifest, direct .minecraft directory structure)");
        return [self parsePlainZipModpack:archive filePath:filePath error:error];
    }

    if (error) {
        *error = [NSError errorWithDomain:@"ModpackImportError"
                                     code:1003
                                 userInfo:@{NSLocalizedDescriptionKey: @"无效的整合包格式。缺少 modrinth.index.json、mmc-pack.json、manifest.json 或 .minecraft 目录结构"}];
    }
    return nil;
}

/// 解析 MMC (MultiMC / Prism Launcher) 格式整合包
/// mmc-pack.json 结构：
///   {
///     "components": [
///       {"uid": "net.minecraft", "version": "1.20.1"},
///       {"uid": "net.fabricmc.fabric-loader", "version": "0.15.7"},
///       ...
///     ]
///   }
/// instance.cfg（key=value 格式，可选）：
///   name=My Modpack
/// MMC 整合包的 .minecraft 目录在 zip 内通常以 .minecraft/ 前缀存在
- (nullable NSDictionary *)parseMMCPack:(UZKArchive *)archive
                          mmcPackData:(NSData *)mmcPackData
                              filePath:(NSString *)filePath
                                 error:(NSError **)error {
    NSError *jsonError = nil;
    NSDictionary *mmcPack = [NSJSONSerialization JSONObjectWithData:mmcPackData options:0 error:&jsonError];
    if (jsonError || ![mmcPack isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1006
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法解析 mmc-pack.json"}];
        }
        return nil;
    }

    NSArray *components = mmcPack[@"components"];
    if (![components isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1007
                                     userInfo:@{NSLocalizedDescriptionKey: @"mmc-pack.json 缺少 components 数组"}];
        }
        return nil;
    }

    NSString *minecraftVersion = nil;
    NSString *loader = @"Vanilla";
    NSString *loaderVersion = @"";

    // 遍历 components 解析 MC 版本和加载器
    for (NSDictionary *comp in components) {
        if (![comp isKindOfClass:[NSDictionary class]]) continue;
        NSString *uid = comp[@"uid"];
        NSString *version = comp[@"version"];
        if (![uid isKindOfClass:[NSString class]] || ![version isKindOfClass:[NSString class]]) continue;

        if ([uid isEqualToString:@"net.minecraft"]) {
            minecraftVersion = version;
        } else if ([uid isEqualToString:@"net.fabricmc.fabric-loader"]) {
            loader = @"Fabric";
            loaderVersion = version;
        } else if ([uid isEqualToString:@"org.quiltmc.quilt-loader"]) {
            loader = @"Quilt";
            loaderVersion = version;
        } else if ([uid isEqualToString:@"net.minecraftforge"]) {
            loader = @"Forge";
            loaderVersion = version;
        } else if ([uid isEqualToString:@"net.neoforged"]) {
            loader = @"NeoForge";
            loaderVersion = version;
        }
    }

    // 从 instance.cfg 读取 name（可选）
    NSString *name = [filePath.lastPathComponent stringByDeletingPathExtension];
    NSError *cfgError = nil;
    NSData *cfgData = [archive extractDataFromFile:@"instance.cfg" error:&cfgError];
    if (cfgData) {
        NSString *cfgContent = [[NSString alloc] initWithData:cfgData encoding:NSUTF8StringEncoding];
        for (NSString *line in [cfgContent componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"name="]) {
                NSString *parsedName = [line substringFromIndex:@"name=".length];
                parsedName = [parsedName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (parsedName.length > 0) {
                    name = parsedName;
                }
                break;
            }
        }
    }

    NSString *modpackId = [NSString stringWithFormat:@"mmc_%@", [[NSUUID UUID] UUIDString]];
    NSString *iconBase64 = [self extractIconFromArchive:archive];

    NSLog(@"[ModpackImport] MMC modpack: name=%@, MC=%@, loader=%@ %@", name, minecraftVersion, loader, loaderVersion);

    return @{
        @"id": modpackId,
        @"name": name,
        @"version": @"1.0.0",
        @"minecraftVersion": minecraftVersion ?: @"unknown",
        @"loader": loader,
        @"loaderVersion": loaderVersion,
        @"filePath": filePath,
        @"format": @"mmc",
        @"files": @[],
        @"iconBase64": iconBase64 ?: @""
    };
}

/// 检测 zip 是否是 Plain ZIP 整合包（无 manifest，直接含 .minecraft 目录结构）
/// 判断条件：zip 中至少含有一个 .minecraft 风格的顶层目录或文件
- (BOOL)isPlainZipModpack:(UZKArchive *)archive {
    // .minecraft 风格的顶层目录/文件特征
    NSArray<NSString *> *knownTopLevelEntries = @[
        @"mods/", @"config/", @"versions/", @"saves/", @"resourcepacks/",
        @"shaderpacks/", @"defaultconfigs/", @"kubejs/", @"scripts/",
        @"localization/", @"patchouli_books/", @"options.txt",
        @"optionsof.txt", @"optionsshaders.txt", @"servers.dat",
        @"launcher_profiles.json", @"hotbar.nbt"
    ];
    __block BOOL hasMinecraftStructure = NO;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *filename = fileInfo.filename;
        // 兼容 .minecraft/ 前缀（HMCL 导出格式）
        NSString *normalized = filename;
        if ([normalized hasPrefix:@".minecraft/"]) {
            normalized = [normalized substringFromIndex:@".minecraft/".length];
        }
        // 跳过 macOS 的 __MACOSX 目录和隐藏文件
        if ([filename hasPrefix:@"__MACOSX/"]) return;
        if ([filename.lastPathComponent hasPrefix:@"."]) return;

        for (NSString *entry in knownTopLevelEntries) {
            if ([normalized hasPrefix:entry] || [normalized isEqualToString:[entry stringByDeletingPathExtension]]) {
                hasMinecraftStructure = YES;
                *stop = YES;
                return;
            }
        }
    } error:nil];
    return hasMinecraftStructure;
}

/// 解析 Plain ZIP 整合包
/// Plain ZIP 无 manifest，需要：
///   1. 从 versions/<version>/<version>.json 推断 minecraft 版本
///   2. loader 默认 Vanilla（无法从 zip 可靠推断，需用户后续手动安装）
///   3. 整个 zip 根目录作为 overrides 提取到 gameDir
- (nullable NSDictionary *)parsePlainZipModpack:(UZKArchive *)archive filePath:(NSString *)filePath error:(NSError **)error {
    (void)error;
    NSString *minecraftVersion = [self detectMinecraftVersionFromArchive:archive] ?: @"unknown";
    NSString *name = [filePath.lastPathComponent stringByDeletingPathExtension];
    NSString *modpackId = [NSString stringWithFormat:@"plainzip_%@", [[NSUUID UUID] UUIDString]];

    NSLog(@"[ModpackImport] Plain ZIP modpack: name=%@, inferred MC version=%@", name, minecraftVersion);

    return @{
        @"id": modpackId,
        @"name": name,
        @"version": @"1.0.0",
        @"minecraftVersion": minecraftVersion,
        @"loader": @"Vanilla",
        @"loaderVersion": @"",
        @"filePath": filePath,
        @"format": @"plainzip",
        @"files": @[],
        @"iconBase64": [self extractIconFromArchive:archive] ?: @""
    };
}

/// 从 zip 的 versions/<version>/<version>.json 路径推断 minecraft 版本
- (nullable NSString *)detectMinecraftVersionFromArchive:(UZKArchive *)archive {
    __block NSString *detectedVersion = nil;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *filename = fileInfo.filename;
        // 兼容 .minecraft/ 前缀
        if ([filename hasPrefix:@".minecraft/"]) {
            filename = [filename substringFromIndex:@".minecraft/".length];
        }
        // 匹配 versions/<version>/<version>.json
        if ([filename hasPrefix:@"versions/"] && [filename hasSuffix:@".json"]) {
            NSArray *parts = [filename componentsSeparatedByString:@"/"];
            if (parts.count >= 3) {
                NSString *versionFromPath = parts[parts.count - 2];
                // 优先选择纯 minecraft 版本（不含 -forge-/-neoforge-/-fabric- 等后缀）
                if (detectedVersion.length == 0) {
                    detectedVersion = versionFromPath;
                }
                // 如果是纯版本号（无 loader 后缀），优先采用
                if (![versionFromPath containsString:@"-forge-"] &&
                    ![versionFromPath containsString:@"-neoforge-"] &&
                    ![versionFromPath containsString:@"-fabric-"] &&
                    ![versionFromPath containsString:@"-quilt-"]) {
                    detectedVersion = versionFromPath;
                    *stop = YES;
                }
            }
        }
    } error:nil];
    return detectedVersion;
}

- (nullable NSDictionary *)parseModrinthModpack:(UZKArchive *)archive indexData:(NSData *)indexData filePath:(NSString *)filePath error:(NSError **)error {
    NSError *jsonError = nil;
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&jsonError];

    if (jsonError || ![indexDict isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1004
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法解析 modrinth.index.json"}];
        }
        return nil;
    }

    NSDictionary *dependencies = indexDict[@"dependencies"];
    NSString *minecraftVersion = nil, *loader = nil, *loaderVersion = nil;
    [self resolveModrinthDependencies:dependencies
                                loader:&loader
                         loaderVersion:&loaderVersion
                          minecraftVer:&minecraftVersion];

    NSString *name = indexDict[@"name"] ?: [filePath.lastPathComponent stringByDeletingPathExtension];
    NSString *version = indexDict[@"versionId"] ?: @"1.0.0";
    NSString *modpackId = [NSString stringWithFormat:@"modrinth_%@", [[NSUUID UUID] UUIDString]];

    // 提取 icon.png (如果有)
    NSString *iconBase64 = [self extractIconFromArchive:archive];

    return @{
        @"id": modpackId,
        @"name": name,
        @"version": version,
        @"minecraftVersion": minecraftVersion ?: @"unknown",
        @"loader": loader ?: @"Vanilla",
        @"loaderVersion": loaderVersion ?: @"",
        @"filePath": filePath,
        @"format": @"modrinth",
        @"indexData": indexDict,
        @"files": indexDict[@"files"] ?: @[],
        @"iconBase64": iconBase64 ?: @""
    };
}

- (nullable NSDictionary *)parseManifestModpack:(UZKArchive *)archive manifestData:(NSData *)manifestData filePath:(NSString *)filePath error:(NSError **)error {
    NSError *jsonError = nil;
    NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&jsonError];

    if (jsonError || ![manifestDict isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1005
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法解析 manifest.json"}];
        }
        return nil;
    }

    NSDictionary *minecraft = manifestDict[@"minecraft"];
    NSString *minecraftVersion = minecraft[@"version"];

    NSString *loader = nil, *loaderVersion = nil;
    [self resolveCurseForgeLoader:minecraft[@"modLoaders"]
                           loader:&loader
                    loaderVersion:&loaderVersion];

    NSString *name = manifestDict[@"name"] ?: [filePath.lastPathComponent stringByDeletingPathExtension];
    NSString *version = manifestDict[@"version"] ?: @"1.0.0";
    NSString *modpackId = [NSString stringWithFormat:@"curseforge_%@", [[NSUUID UUID] UUIDString]];

    // 提取 icon (CurseForge 整合包通常没有，尝试 modpack.png 或 pack.png)
    NSString *iconBase64 = [self extractIconFromArchive:archive];

    return @{
        @"id": modpackId,
        @"name": name,
        @"version": version,
        @"minecraftVersion": minecraftVersion ?: @"unknown",
        @"loader": loader ?: @"Vanilla",
        @"loaderVersion": loaderVersion ?: @"",
        @"filePath": filePath,
        @"format": @"curseforge",
        @"manifestData": manifestDict,
        @"files": manifestDict[@"files"] ?: @[],
        @"iconBase64": iconBase64 ?: @""
    };
}

/// 从整合包内尝试提取 icon.png/modpack.png/pack.png，返回 base64 data URI
- (nullable NSString *)extractIconFromArchive:(UZKArchive *)archive {
    NSArray<NSString *> *iconCandidates = @[@"icon.png", @"modpack.png", @"pack.png"];
    for (NSString *name in iconCandidates) {
        NSError *err = nil;
        NSData *data = [archive extractDataFromFile:name error:&err];
        if (data && !err) {
            return [NSString stringWithFormat:@"data:image/png;base64,%@",
                    [data base64EncodedStringWithOptions:0]];
        }
    }
    return nil;
}

#pragma mark - Import Modpack

- (BOOL)importModpack:(NSDictionary *)modpackInfo error:(NSError **)error {
    return [self importModpack:modpackInfo progress:nil error:error];
}

- (BOOL)importModpack:(NSDictionary *)modpackInfo
             progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                error:(NSError **)error {
    // 阶段5修复：每次导入开始时清空失败列表（参照 FCL DownloadList.reset()）
    // Phase 3：同时清空 404 跳过列表，避免跨次导入残留
    @synchronized(self) {
        [self.failedFilesInternal removeAllObjects];
        [self.skippedFilesInternal removeAllObjects];
    }

    NSString *filePath = modpackInfo[@"filePath"];
    NSString *format = modpackInfo[@"format"];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"整合包文件不存在"}];
        }
        return NO;
    }

    if ([self checkCancelledWithError:error]) {
        return NO;
    }

    if (progress) progress(0.05, @"准备整合包目录");

    NSString *modpackId = modpackInfo[@"id"];
    NSString *gameDirAbsolute = [self absoluteGameDirForModpackId:modpackId];
    NSString *gameDirRelative = [self relativeGameDirForModpackId:modpackId];

    // 清理可能存在的旧目录
    if ([fm fileExistsAtPath:gameDirAbsolute]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
    }
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:gameDirAbsolute
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirError]) {
        if (error) *error = dirError;
        return NO;
    }

    // 创建 mods 目录
    NSString *modsDir = [gameDirAbsolute stringByAppendingPathComponent:@"mods"];
    [fm createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];

    // 创建 versions 目录
    NSString *versionsDir = [gameDirAbsolute stringByAppendingPathComponent:@"versions"];
    [fm createDirectoryAtPath:versionsDir withIntermediateDirectories:YES attributes:nil error:nil];

    // 取消检查点
    if ([self checkCancelledWithError:error]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // 第 1 步: 解压 overrides/client-overrides (Modrinth) 或 overrides (CurseForge/MMC) 到 gameDir
    if (progress) progress(0.10, @"正在解压 overrides");
    NSError *extractError = nil;
    BOOL extractSuccess = [self extractOverrides:filePath format:format toDirectory:gameDirAbsolute error:&extractError];
    if (!extractSuccess) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        if (error) *error = extractError;
        return NO;
    }

    // 取消检查点
    if ([self checkCancelledWithError:error]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // 第 2 步: 下载 mod 文件列表
    NSArray *modFiles = modpackInfo[@"files"];
    if (modFiles.count > 0) {
        if (progress) progress(0.15, [NSString stringWithFormat:@"正在下载 %lu 个 mod 文件", (unsigned long)modFiles.count]);
        NSError *downloadError = nil;
        BOOL downloadSuccess = [self downloadModFiles:modpackInfo toModsDirectory:modsDir progress:progress error:&downloadError];
        if (!downloadSuccess) {
            // mod 下载失败不阻断导入，只记录警告
            NSLog(@"[ModpackImport] Mod download partially failed: %@", downloadError.localizedDescription);
        }
    }

    // 取消检查点
    if ([self checkCancelledWithError:error]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // 第 3 步: 安装模组加载器
    if (progress) progress(0.85, @"正在安装模组加载器");
    NSString *loader = modpackInfo[@"loader"];
    NSString *loaderVersion = modpackInfo[@"loaderVersion"];
    NSString *minecraftVersion = modpackInfo[@"minecraftVersion"];
    NSString *versionId = [self versionIdForModpack:modpackInfo];

    NSError *loaderError = nil;
    BOOL loaderSuccess = [self installModLoader:loader
                                 loaderVersion:loaderVersion
                                minecraftVersion:minecraftVersion
                                       versionId:versionId
                                   gameDirAbsolute:gameDirAbsolute
                                          error:&loaderError];
    if (!loaderSuccess) {
        // 加载器安装失败不阻断 (用户可能已经手动安装)
        NSLog(@"[ModpackImport] Loader installation failed (user may have already installed): %@", loaderError.localizedDescription);
    }

    // 阶段5修复（参照 FCL ModpackHelper.ensureCompleteVersion）：
    // installModLoader 只写入了 loader 的 version.json，但父版本（原版 MC）的
    // version.json、libraries、assets 都还没下载。之前用户启动整合包时会报
    // "找不到 net.minecraft.client.main.Main" 或 libraries 缺失，正是因为这一步缺失。
    // 这里触发完整版本下载，确保启动时所有依赖文件都就位。
    if (progress) progress(0.86, @"正在下载游戏文件（库 + 资源）");
    NSError *versionDLError = nil;
    BOOL versionDLOK = [self ensureCompleteVersionInstalled:versionId
                                          minecraftVersion:minecraftVersion
                                                 progress:progress
                                                    error:&versionDLError];
    if (!versionDLOK) {
        NSLog(@"[ModpackImport] Warning: Full version download failed: %@", versionDLError.localizedDescription);
        // 不阻断导入：用户可能已手动下载过原版文件，或者后续启动时按需下载
        // 但要把失败信息记入 failedFiles 让用户知晓
        @synchronized(self) {
            [self.failedFilesInternal addObject:@{
                @"fileName": [NSString stringWithFormat:@"%@ (游戏文件)", versionId],
                @"url": @"",
                @"reason": versionDLError.localizedDescription ?: @"游戏文件下载失败",
                @"format": @"version"
            }];
        }
    }

    // 取消检查点
    if ([self checkCancelledWithError:error]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // 第 4 步: 写 profile
    if (progress) progress(0.95, @"正在写入配置文件");
    NSString *profileName = [self createProfileForModpack:modpackInfo
                                          gameDirRelative:gameDirRelative
                                                versionId:versionId
                                                    error:error];
    if (!profileName) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // 第 5 步: 持久化整合包元信息
    NSMutableDictionary *savedModpack = [modpackInfo mutableCopy];
    savedModpack[@"gameDirAbsolute"] = gameDirAbsolute;
    savedModpack[@"gameDirRelative"] = gameDirRelative;
    savedModpack[@"profileName"] = profileName;
    savedModpack[@"importDate"] = [self iso8601StringFromDate:[NSDate date]];
    [self saveImportedModpack:savedModpack];

    if (progress) progress(1.0, @"导入完成");
    return YES;
}

/// 根据 modpackInfo 计算 lastVersionId
- (NSString *)versionIdForModpack:(NSDictionary *)modpackInfo {
    NSString *loader = modpackInfo[@"loader"];
    NSString *loaderVersion = modpackInfo[@"loaderVersion"];
    NSString *minecraftVersion = modpackInfo[@"minecraftVersion"];

    if ([loader isEqualToString:@"Fabric"]) {
        return [NSString stringWithFormat:@"fabric-loader-%@-%@", loaderVersion, minecraftVersion];
    } else if ([loader isEqualToString:@"Quilt"]) {
        return [NSString stringWithFormat:@"quilt-loader-%@-%@", loaderVersion, minecraftVersion];
    } else if ([loader isEqualToString:@"Forge"]) {
        return [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, loaderVersion];
    } else if ([loader isEqualToString:@"NeoForge"]) {
        // NeoForge 版本号本身已包含 MC 版本信息，例如 47.1.0 (对应 1.20.1)
        // 但在版本目录里仍用 <mc>-neoforge-<loader> 形式以便区分
        return [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, loaderVersion];
    } else {
        return minecraftVersion ?: @"";
    }
}

/// 解压 overrides 目录到 gameDir
/// Modrinth: overrides + client-overrides
/// CurseForge: overrides
/// Plain ZIP: 整个 zip 根目录作为 overrides 提取（兼容 .minecraft/ 前缀）
- (BOOL)extractOverrides:(NSString *)filePath format:(NSString *)format toDirectory:(NSString *)destDir error:(NSError **)error {
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:filePath error:&archiveError];
    if (archiveError || !archive) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:3001
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法打开整合包压缩文件"}];
        }
        return NO;
    }

    // Plain ZIP：整个 zip 根目录作为 overrides 提取到 gameDir
    // 兼容 .minecraft/ 前缀（HMCL 导出格式）和 __MACOSX 目录（macOS 创建的元数据）
    if ([format isEqualToString:@"plainzip"] || [format isEqualToString:@"mmc"]) {
        NSLog(@"[ModpackImport] %@: extracting zip root to gameDir", format);
        // 关键修复（多启动器兼容）：versions/ 目录特殊处理
        // Java 端 Tools.java 的 DIR_HOME_VERSION 固定指向 POJAV_GAME_DIR/versions，
        // 不从 profile gameDir 读取。因此 Plain ZIP/MMC 中的 versions/ 必须提取到主目录，
        // 否则启动时报"找不到版本信息"。
        const char *pojavGameDir = getenv("POJAV_GAME_DIR");
        NSString *mainVersionsDir = pojavGameDir ?
            [NSString stringWithFormat:@"%s/versions", pojavGameDir] :
            [destDir stringByAppendingPathComponent:@"versions"];

        [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
            // 取消检查点（在长循环内频繁检查）
            @synchronized(self) {
                if (self.cancelled) {
                    *stop = YES;
                    return;
                }
            }

            NSString *filename = fileInfo.filename;
            // 兼容 .minecraft/ 前缀（HMCL/MMC 导出格式）
            if ([filename hasPrefix:@".minecraft/"]) {
                filename = [filename substringFromIndex:@".minecraft/".length];
            }
            // 跳过 macOS 的 __MACOSX 目录和隐藏文件
            if ([filename hasPrefix:@"__MACOSX/"]) return;
            if ([filename.lastPathComponent hasPrefix:@"."]) return;
            // 跳过 MMC 的元信息文件（已在 parseMMCPack 中处理过）
            if ([format isEqualToString:@"mmc"] &&
                ([filename isEqualToString:@"mmc-pack.json"] ||
                 [filename isEqualToString:@"instance.cfg"] ||
                 [filename isEqualToString:@"pack.png"])) {
                return;
            }
            if (filename.length == 0) return;

            // versions/ 前缀的文件提取到主目录 POJAV_GAME_DIR/versions/
            // 其他文件提取到 gameDirAbsolute（保持整合包隔离）
            NSString *baseDir = destDir;
            NSString *relativePath = filename;
            if ([filename hasPrefix:@"versions/"]) {
                baseDir = mainVersionsDir;
                relativePath = [filename substringFromIndex:@"versions/".length];
                // 如果 relativePath 仍以 versions/ 开头（如 versions/1.20.1/1.20.1.json），保留
                if ([relativePath hasPrefix:@"versions/"]) {
                    relativePath = [relativePath substringFromIndex:@"versions/".length];
                }
            }

            NSString *destItemPath = [baseDir stringByAppendingPathComponent:relativePath];
            NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
            BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
                                                              withIntermediateDirectories:YES
                                                                              attributes:nil
                                                                                   error:error];
            if (!createdDir) {
                *stop = YES;
                return;
            }
            if (fileInfo.isDirectory) return;

            NSData *data = [archive extractData:fileInfo error:error];
            BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
            *stop = !data || !written;
        } error:error];
        if (error && *error) {
            NSLog(@"[ModpackImport] %@ extraction failed: %@", format, *error);
            return NO;
        }
        // 取消时清理
        @synchronized(self) {
            if (self.cancelled) {
                if (error) {
                    *error = [NSError errorWithDomain:@"ModpackImportError"
                                                 code:9999
                                             userInfo:@{NSLocalizedDescriptionKey: @"导入已取消"}];
                }
                return NO;
            }
        }
        return YES;
    }

    // Modrinth: 解压 overrides 和 client-overrides (后者覆盖前者)
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destDir error:error];
    if (error && *error) {
        return NO;
    }

    if ([format isEqualToString:@"modrinth"]) {
        [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destDir error:error];
        if (error && *error) {
            // client-overrides 不存在不算错误
            NSLog(@"[ModpackImport] client-overrides extract (may not exist): %@", *error);
            *error = nil;
        }
    }

    return YES;
}

/// 下载 mod 文件列表（Phase 3 并发改造，spec Task 3.1/3.2/3.3）
/// Modrinth 格式: files[].downloads 是直接 URL 数组，files[].path 是相对路径，
///                files[].hashes.sha1 用于完整性校验（Task 3.2）
/// CurseForge 格式: files[].projectID + fileID 延迟到并发下载阶段解析真实 CDN URL（Task 3.3）
///
/// 并发模型：dispatch_group + dispatch_semaphore(12) 限流。每个文件在并发槽内构造
/// PLDownloadRequest（镜像候选经 PLMirrorCenter AssetDownload 重写）交 PLDownloadClient
/// 异步下载，group_enter/group_leave 包裹文件生命周期；单候选指数退避重试、镜像换源、
/// SHA1/zip 完整性校验与断点续传均由 PLDownloadClient 内部处理——旧实现的手工重试循环与
/// [NSThread sleepForTimeInterval:] 重试等待已删除。
///
/// 本方法整体保持同步语义：末尾 dispatch_group_wait 阻塞直至全部文件收尾再返回 BOOL。
/// 注意：调用方（importModpack）运行在后台队列（ModpackImportViewController /
/// DownloadViewController 均先 dispatch_async 到全局队列再调用），阻塞该线程是安全且必须的
/// ——调用方依赖同步返回值决定后续加载器安装步骤。
- (BOOL)downloadModFiles:(NSDictionary *)modpackInfo toModsDirectory:(NSString *)modsDir progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress error:(NSError **)error {
    NSString *format = modpackInfo[@"format"];
    NSArray *files = modpackInfo[@"files"];
    if (files.count == 0) return YES;

    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    // 修复整合包图标不显示：原实现将 modpackInfo[@"iconBase64"]（base64 编码的图片数据字符串）
    // 直接赋给 iconURL 字段，传给 setImageWithURL: 时 NSURL URLWithString: 返回 nil（base64 不是合法 URL），
    // 导致整合包下载任务的图标永远不显示。
    // 正确做法：将 base64 数据解码为 UIImage，保存到临时文件，使用文件 URL。
    NSString *iconURL = [self resolveIconURLFromModpackInfo:modpackInfo];

    BOOL isCurseForge = [format isEqualToString:@"curseforge"];

    // ---------- 第 1 步：串行预筛（纯内存解析，无网络 IO） ----------
    // Modrinth：剔除 server-only（env.client=="unsupported"）与缺失下载 URL 的条目；
    // CurseForge：仅剔除缺失 projectID/fileID 的条目，URL/文件名解析延迟到并发槽内
    //（Task 3.3：旧实现在主循环串行执行 HEAD 文件名解析，逐文件最多 15s 超时，是导入缓慢主因之一）。
    NSMutableArray<NSDictionary *> *pendingFiles = [NSMutableArray arrayWithCapacity:files.count];
    NSUInteger skippedServerOnly = 0;
    NSUInteger skippedMissingMeta = 0;
    for (NSDictionary *fileInfo in files) {
        // 取消检查点
        if ([self checkCancelledWithError:error]) {
            return NO;
        }
        if (![fileInfo isKindOfClass:[NSDictionary class]]) {
            skippedMissingMeta++;
            continue;
        }

        if (isCurseForge) {
            if (!fileInfo[@"projectID"] || !fileInfo[@"fileID"]) {
                skippedMissingMeta++;
                continue;
            }
            [pendingFiles addObject:fileInfo];
            continue;
        }

        // env 字段过滤：Modrinth 文件可声明仅 server 或仅 client 适用。
        // 启动器是客户端，跳过 env.client=="unsupported" 的文件（避免下载服务端专用 mod）。
        // env 缺失或 env.client=="required"/"optional" 时正常下载。
        NSDictionary *env = fileInfo[@"env"];
        NSString *clientEnv = env[@"client"];
        if ([clientEnv isKindOfClass:[NSString class]] && [clientEnv isEqualToString:@"unsupported"]) {
            skippedServerOnly++;
            NSLog(@"[ModpackImport] Skipping server-only mod: %@", fileInfo[@"path"]);
            continue;
        }

        NSArray *downloads = [fileInfo[@"downloads"] isKindOfClass:[NSArray class]] ? fileInfo[@"downloads"] : @[];
        if (![downloads.firstObject isKindOfClass:[NSString class]] || ![fileInfo[@"path"] isKindOfClass:[NSString class]]) {
            // 关键修复：URL 为空时不应静默跳过而不计数，否则进度条永远卡住、用户也无法感知有缺失。
            // 预筛剔除并计入警告计数（与旧行为一致：不算失败，仅日志提示）。
            skippedMissingMeta++;
            NSLog(@"[ModpackImport] Warning: Modrinth file %@ missing download URL, skipping", fileInfo[@"path"]);
            continue;
        }
        [pendingFiles addObject:fileInfo];
    }
    if (skippedServerOnly > 0) {
        NSLog(@"[ModpackImport] Modrinth modpack: skipped %lu server-only mods", (unsigned long)skippedServerOnly);
    }
    if (skippedMissingMeta > 0) {
        NSLog(@"[ModpackImport] Warning: %lu files skipped due to missing download metadata", (unsigned long)skippedMissingMeta);
    }

    NSUInteger total = pendingFiles.count;

    // ---------- 第 2 步：并发下载（dispatch_group + 12 槽限流） ----------
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t slotSemaphore = dispatch_semaphore_create(12);
    dispatch_queue_t concurrentQueue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    // 并发聚合计数器（@synchronized(aggregate) 保护）：
    //   success   成功文件数；failed 失败文件数；skipped404 因 404/资源不存在跳过的文件数
    //   completed 已收尾（成功+失败+跳过）文件数，驱动主进度条
    //   bytes     已传输字节累计（PLDownloadClient progress delta 直接累加；负 delta 回退语义下仍贴合真实进度）
    NSMutableDictionary *aggregate = [@{
        @"success": @(0),
        @"failed": @(0),
        @"skipped404": @(0),
        @"completed": @(0),
        @"bytes": @(0),
    } mutableCopy];

    for (NSDictionary *fileInfo in pendingFiles) {
        // 取消检查点：停止提交新任务；已在途任务等待其自然收尾后由 group_wait 返回
        if ([self checkCancelledWithError:error]) {
            break;
        }

        dispatch_group_enter(group);
        // 提交前限流：占用一个并发槽位（等待发生在调用线程，即后台导入线程，可接受）。
        // 槽位在该文件下载 completion 中释放，保证同时在途的下载不超过 12 个。
        dispatch_semaphore_wait(slotSemaphore, DISPATCH_TIME_FOREVER);

        dispatch_async(concurrentQueue, ^{
            if (self.cancelled) {
                dispatch_semaphore_signal(slotSemaphore);
                dispatch_group_leave(group);
                return;
            }

            // ---- 构造单个文件的下载请求 ----
            NSString *fileName = nil;
            NSString *destPath = nil;
            NSString *expectedSHA1 = nil;
            NSString *recordURL = @"";
            NSMutableArray<NSURL *> *candidates = [NSMutableArray array];

            if (isCurseForge) {
                // ===== Task 3.3：CurseForge 延迟解析（占用并发槽，与其他文件的解析/下载并行）=====
                long long projectID = [fileInfo[@"projectID"] longLongValue];
                long long fileID = [fileInfo[@"fileID"] longLongValue];

                // 文件名：优先 manifest 透传的真实 fileName；缺失时经 HEAD 请求解析
                //（Content-Disposition 或重定向 URL 末段），避免 mods/ 里全是 "12345-67890.jar"
                // 这种用户无法识别的 fallback 名称。旧实现串行执行该请求阻塞整个导入流程，
                // 现在与其他文件并发进行，解析本身即为提速。
                BOOL hasRealFileName = NO;
                fileName = fileInfo[@"fileName"];
                if ([fileName isKindOfClass:[NSString class]] && fileName.length > 0) {
                    hasRealFileName = YES;
                } else {
                    NSString *realName = [self fetchCurseForgeRealFileName:projectID fileID:fileID];
                    if (realName.length > 0) {
                        fileName = realName;
                        hasRealFileName = YES;
                        NSLog(@"[ModpackImport] Resolved real filename via HEAD: projectID=%lld fileID=%lld → %@",
                              projectID, fileID, realName);
                    } else {
                        fileName = [NSString stringWithFormat:@"%lld-%lld.jar", projectID, fileID];
                    }
                }
                destPath = [modsDir stringByAppendingPathComponent:fileName];

                // 候选列表（按尝试顺序）：
                //   1) BMCLAPI 下载端点（主源：无需 API Key，302 重定向到真实文件）
                //   2) 官方 Edge CDN 直链（真实文件名已知时；经 PLMirrorCenter AssetDownload
                //      重写可附带 MCIM 镜像候选，官方/镜像先后由用户下载源策略决定）
                //   3) cdn.curseforge.com 下载端点兜底（不依赖文件名，靠服务端重定向）
                NSURL *bmclURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/curseforge/files/%lld/%lld/download",
                                                       PLMirrorBMCLAPIRootURL, projectID, fileID]];
                if (bmclURL) {
                    [candidates addObject:bmclURL];
                    recordURL = bmclURL.absoluteString;
                }
                if (hasRealFileName) {
                    NSString *encodedName = [fileName stringByAddingPercentEncodingWithAllowedCharacters:
                                             NSCharacterSet.URLPathAllowedCharacterSet];
                    NSURL *edgeURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://edge.forgecdn.net/files/%lld/%03lld/%@",
                                                           fileID / 1000, fileID % 1000, encodedName ?: fileName]];
                    if (edgeURL) {
                        for (NSURL *u in [PLMirrorCenter candidateURLsForOriginalURL:edgeURL
                                                                        resourceType:PLMirrorResourceTypeAssetDownload]) {
                            if (![candidates containsObject:u]) [candidates addObject:u];
                        }
                    }
                }
                NSURL *cfURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.curseforge.com/files/%lld/%lld/download",
                                                     projectID, fileID]];
                if (cfURL) {
                    for (NSURL *u in [PLMirrorCenter candidateURLsForOriginalURL:cfURL
                                                                    resourceType:PLMirrorResourceTypeAssetDownload]) {
                        if (![candidates containsObject:u]) [candidates addObject:u];
                    }
                }
            } else {
                // ===== Modrinth：downloads 数组逐一经 PLMirrorCenter（AssetDownload）重写为镜像候选 =====
                NSString *relPath = fileInfo[@"path"];
                NSArray *downloads = [fileInfo[@"downloads"] isKindOfClass:[NSArray class]] ? fileInfo[@"downloads"] : @[];
                fileName = relPath.lastPathComponent;

                // 关键修复（保留）：之前 `if (![relPath hasPrefix:@"mods/"]) continue;` 会丢弃所有非
                // mods/ 前缀的文件，包括 shaderpacks/、resourcepacks/、datapacks/ 等用户自定义资源，
                // 与"模组不完整"问题密切相关。根据 path 前缀分发到对应目录（overrides 已另行解压）。
                NSString *destDir = nil;
                if ([relPath hasPrefix:@"mods/"]) {
                    destDir = modsDir;
                } else if ([relPath hasPrefix:@"shaderpacks/"]) {
                    destDir = [modsDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"shaderpacks"];
                } else if ([relPath hasPrefix:@"resourcepacks/"]) {
                    destDir = [modsDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"resourcepacks"];
                } else if ([relPath hasPrefix:@"datapacks/"]) {
                    destDir = [modsDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"datapacks"];
                } else {
                    // 其他前缀（如 config/、defaultconfigs/）通常在 overrides 中；若 files[] 出现，
                    // 按相对路径完整写入 gameDir 根。
                    destDir = [modsDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:relPath.stringByDeletingLastPathComponent];
                }
                // 处理子目录（如 mods/inner/sub.jar）
                // 阶段5修复（保留）：relPath 不含 "/" 时 rangeOfString: 返回 NSNotFound，
                // 直接 +1 会整数溢出，导致 substringFromIndex: 抛出 NSRangeException 崩溃。
                // 根目录文件（如 "config.toml"）保留原文件名直接拼到 destDir。
                NSRange firstSlashRange = [relPath rangeOfString:@"/"];
                NSString *relativeUnder = (firstSlashRange.location == NSNotFound)
                    ? relPath.lastPathComponent
                    : [relPath substringFromIndex:firstSlashRange.location + 1];
                destPath = [destDir stringByAppendingPathComponent:relativeUnder];

                // Task 3.2：.mrpack index 的 files[].hashes.sha1 透传给 PLDownloadClient 做流式校验，
                // 校验失败由其内部自动重试/换源；长度非法（非 40 位）时不设置，避免误判为校验失败。
                NSString *sha1 = fileInfo[@"hashes"][@"sha1"];
                if ([sha1 isKindOfClass:[NSString class]] && sha1.length == 40) {
                    expectedSHA1 = sha1;
                }

                for (id u in downloads) {
                    if (![u isKindOfClass:[NSString class]]) continue;
                    // 阶段5修复（保留）：非法 URL（控制字符/空格等使 URLWithString: 返回 nil）直接剔除
                    NSURL *nu = [NSURL URLWithString:u];
                    if (!nu) continue;
                    if (recordURL.length == 0) recordURL = u;
                    for (NSURL *c in [PLMirrorCenter candidateURLsForOriginalURL:nu
                                                                    resourceType:PLMirrorResourceTypeAssetDownload]) {
                        if (![candidates containsObject:c]) [candidates addObject:c];
                    }
                }
            }

            // 无有效候选 URL：按失败记录（保持旧 5001 语义），不阻断其他文件
            if (candidates.count == 0 || !destPath) {
                NSLog(@"[ModpackImport] Warning: file %@ has no valid download URL, recording as failed", fileName);
                @synchronized(self) {
                    [self.failedFilesInternal addObject:@{
                        @"fileName": fileName ?: @"(unknown)",
                        @"url": recordURL,
                        @"reason": @"无效的下载链接",
                        @"format": isCurseForge ? @"curseforge" : @"modrinth"
                    }];
                }
                NSUInteger completedNow = 0;
                @synchronized(aggregate) {
                    aggregate[@"failed"] = @([aggregate[@"failed"] unsignedLongValue] + 1);
                    aggregate[@"completed"] = @([aggregate[@"completed"] unsignedLongValue] + 1);
                    completedNow = [aggregate[@"completed"] unsignedLongValue];
                }
                if (progress && total > 0) {
                    progress(0.15 + 0.70 * ((double)completedNow / (double)total),
                             [NSString stringWithFormat:@"下载 mod %lu/%lu: %@",
                              (unsigned long)completedNow, (unsigned long)total, fileName]);
                }
                dispatch_semaphore_signal(slotSemaphore);
                dispatch_group_leave(group);
                return;
            }

            // 注册下载任务卡片（rawTask=nil：底层下载由 PLDownloadClient 全权管理，
            // 重试/换源/断点续传经其内部机制处理，不经 DownloadTaskManager 的 rawTask 通道）
            DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
                registerTaskWithResourceType:DownloadTaskResourceTypeMod
                                resourceName:fileName
                                 displayName:fileName
                              downloadSource:downloadSource
                                     rawTask:nil
                              supportsResume:NO
                                     iconURL:iconURL];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];

            PLDownloadRequest *request = [PLDownloadRequest new];
            request.candidateURLs = [candidates copy];
            request.destinationPath = destPath;
            request.expectedSHA1 = expectedSHA1;
            // taskIdentifier 留空：PLDownloadClient 按 destinationPath + 首 URL 稳定派生，
            // 同一文件重复下载可复用断点续传数据。
            // Task 3.2：无 sha1 时（CurseForge manifest 不含哈希）启用 zip EOCD 兜底校验（.jar 即 zip 容器）。
            request.allowZipFallbackCheck = (expectedSHA1 == nil);

            __block int64_t receivedBytes = 0; // 仅在本操作的串行回调线程访问，无需加锁
            [[PLDownloadClient sharedClient] startRequest:request
                                                progress:^(int64_t deltaBytes, int64_t totalExpectedBytes) {
                // delta 可为负（镜像切换/重试/断点失效回退），直接累加即可贴合真实进度
                receivedBytes += deltaBytes;
                @synchronized(aggregate) {
                    aggregate[@"bytes"] = @([aggregate[@"bytes"] longLongValue] + deltaBytes);
                }
                double fraction = (totalExpectedBytes > 0) ? (double)receivedBytes / (double)totalExpectedBytes : 0.0;
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                             progress:MIN(MAX(fraction, 0.0), 1.0)
                                                           totalBytes:totalExpectedBytes
                                                      downloadedBytes:MAX(receivedBytes, 0)];
            }
                                                   speed:nil
                                              completion:^(BOOL success, NSError *dlError) {
                if (success) {
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:nil];
                    @synchronized(aggregate) {
                        aggregate[@"success"] = @([aggregate[@"success"] unsignedLongValue] + 1);
                    }
                } else if ([self isResourceNotFoundError:dlError]) {
                    // Task 3.2：404/NotFound 表示资源在该源上不存在（重试/换源也无效），
                    // 跳过并计入"跳过"警告列表（非失败），不阻断导入、不进 failedFiles。
                    NSLog(@"[ModpackImport] File not found (404), skipping: %@ (%@)", fileName, recordURL);
                    @synchronized(self) {
                        [self.skippedFilesInternal addObject:@{
                            @"fileName": fileName ?: @"(unknown)",
                            @"url": recordURL,
                            @"reason": dlError.localizedDescription ?: @"404 Not Found",
                            @"format": isCurseForge ? @"curseforge" : @"modrinth"
                        }];
                    }
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:dlError];
                    @synchronized(aggregate) {
                        aggregate[@"skipped404"] = @([aggregate[@"skipped404"] unsignedLongValue] + 1);
                    }
                } else {
                    // 阶段5修复（参照 FCL DownloadList）：普通失败记入 failedFiles，
                    // 让上层可向用户展示哪些 mod 缺失并提供"重试缺失模组"入口。
                    NSLog(@"[ModpackImport] Mod failed to download: %@ (%@): %@",
                          fileName, recordURL, dlError.localizedDescription);
                    NSMutableDictionary *failedEntry = [@{
                        @"fileName": fileName ?: @"(unknown)",
                        @"url": recordURL ?: @"",
                        @"reason": dlError.localizedDescription ?: @"unknown error",
                        @"format": isCurseForge ? @"curseforge" : @"modrinth"
                    } mutableCopy];
                    if (isCurseForge) {
                        failedEntry[@"projectID"] = fileInfo[@"projectID"] ?: @0;
                        failedEntry[@"fileID"] = fileInfo[@"fileID"] ?: @0;
                    }
                    @synchronized(self) {
                        [self.failedFilesInternal addObject:failedEntry];
                    }
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:dlError];
                    @synchronized(aggregate) {
                        aggregate[@"failed"] = @([aggregate[@"failed"] unsignedLongValue] + 1);
                    }
                }

                // 聚合进度：文件完成计数推进主进度条（0.15 ~ 0.85 区间与既有 UI 语义一致）
                NSUInteger completedNow = 0;
                @synchronized(aggregate) {
                    aggregate[@"completed"] = @([aggregate[@"completed"] unsignedLongValue] + 1);
                    completedNow = [aggregate[@"completed"] unsignedLongValue];
                }
                if (progress && total > 0) {
                    progress(0.15 + 0.70 * ((double)completedNow / (double)total),
                             [NSString stringWithFormat:@"下载 mod %lu/%lu: %@",
                              (unsigned long)completedNow, (unsigned long)total, fileName]);
                }

                // 释放并发槽位并离开 group（与提交侧的 wait/enter 配对）
                dispatch_semaphore_signal(slotSemaphore);
                dispatch_group_leave(group);
            }];
        });
    }

    // 阻塞调用线程（后台导入线程）直至全部文件收尾——保持方法对外同步语义
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    // ---------- 第 3 步：汇总 ----------
    NSUInteger successCount = 0, failedCount = 0, skipped404Count = 0;
    long long transferredBytes = 0;
    @synchronized(aggregate) {
        successCount = [aggregate[@"success"] unsignedLongValue];
        failedCount = [aggregate[@"failed"] unsignedLongValue];
        skipped404Count = [aggregate[@"skipped404"] unsignedLongValue];
        transferredBytes = [aggregate[@"bytes"] longLongValue];
    }
    NSLog(@"[ModpackImport] Mod download completed: %lu/%lu succeeded, %lu failed, %lu skipped(404), %.2f MB transferred",
          (unsigned long)successCount, (unsigned long)total, (unsigned long)failedCount,
          (unsigned long)skipped404Count, (double)transferredBytes / (1024.0 * 1024.0));

    if ([self checkCancelledWithError:error]) {
        return NO;
    }
    // 阶段5修复（参照 FCL DownloadList.finishAll）：任何失败都返回 NO，让上层用
    // self.failedDownloadFiles / self.failedFiles 向用户展示具体缺失的 mod 列表，并提供
    // "重试缺失模组"入口（旧 70% 静默阈值会隐藏"下载不完全"问题，导致启动崩溃）。
    //   - 全部成功（或仅存在 404 跳过，跳过为警告非失败）：返回 YES
    //   - 有失败：返回 NO，error 中带失败文件名（最多 5 个），完整列表经 failedDownloadFiles 访问
    if (total == 0 || failedCount == 0) {
        return YES;
    }

    // 收集失败文件名（用于错误消息）
    NSArray<NSDictionary *> *failedSnapshot = self.failedDownloadFiles;
    NSMutableArray<NSString *> *failedNames = [NSMutableArray arrayWithCapacity:failedSnapshot.count];
    for (NSDictionary *f in failedSnapshot) {
        NSString *n = f[@"fileName"];
        if ([n isKindOfClass:[NSString class]] && n.length > 0) {
            [failedNames addObject:n];
        }
    }
    // 错误消息：成功率 + 失败计数 + 前 5 个失败文件名（避免 error 描述过长）
    NSMutableString *msg = [NSMutableString stringWithFormat:@"整合包模组下载不完整：%lu/%lu 成功，%lu 个失败",
                            (unsigned long)successCount, (unsigned long)total, (unsigned long)failedCount];
    if (failedNames.count > 0) {
        NSUInteger showCount = MIN(failedNames.count, (NSUInteger)5);
        [msg appendString:@"\n失败模组："];
        for (NSUInteger k = 0; k < showCount; k++) {
            [msg appendFormat:@"%@\n", failedNames[k]];
        }
        if (failedNames.count > showCount) {
            [msg appendFormat:@"...等共 %lu 个", (unsigned long)failedNames.count];
        }
    }
    NSLog(@"[ModpackImport] Warning: %@", msg);
    if (error) {
        *error = [NSError errorWithDomain:@"ModpackImportError"
                                     code:5004
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: [msg copy],
                                     @"failedFiles": failedSnapshot
                                 }];
    }
    return NO;
}

/// 同步下载单个文件，并关联到已注册的 DownloadTaskItem(taskId)。
/// Phase 3：内部改为包一层 PLDownloadClient + 信号量等待（镜像候选经 PLMirrorCenter 重写，
/// 退避重试/换源/断点续传由 PLDownloadClient 处理）。existingTask 参数仅为兼容旧调用点
/// 签名保留，底层任务已由 PLDownloadClient 全权接管，传入值会被忽略。
/// 返回 YES 表示文件已成功保存到 destPath；NO 表示下载或保存失败。
///
/// 注意：本方法只允许在后台线程调用（调用方 installModLoader 位于 importModpack 的
/// 后台导入流程中），信号量等待会阻塞调用线程直至下载完成——这是有意保留的同步语义
///（spec Task 3.1：其他调用点依赖同步返回）。
- (BOOL)downloadFileFromURL:(NSString *)urlString
                     toPath:(NSString *)destPath
                     taskId:(nullable NSString *)taskId
                       task:(nullable NSURLSessionDownloadTask *)existingTask
                      error:(NSError **)outError {
    // 统一按资源文件（AssetDownload）处理镜像重写；加载器 installer 的调用点请使用
    // downloadFileFromURL:toPath:taskId:resourceType:error: 变体传入 ModLoader 类型。
    return [self downloadFileFromURL:urlString
                              toPath:destPath
                              taskId:taskId
                        resourceType:PLMirrorResourceTypeAssetDownload
                               error:outError];
}

/// 同步下载单个文件的内部实现（Phase 3）：PLDownloadClient 异步下载 + 信号量同步等待。
/// 仅后台线程调用（见上）。resourceType 决定镜像重写体系（AssetDownload / ModLoader）。
- (BOOL)downloadFileFromURL:(NSString *)urlString
                     toPath:(NSString *)destPath
                     taskId:(nullable NSString *)taskId
               resourceType:(PLMirrorResourceType)resourceType
                      error:(NSError **)outError {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        // 阶段5修复（保留）：[NSURL URLWithString:] 对非法字符串（控制字符/空格等）返回 nil，
        // 必须显式判断，避免底层 API 抛 NSInvalidArgumentException 崩溃。
        NSError *invalidURLError = [NSError errorWithDomain:@"ModpackImportError"
                                                       code:5001
                                                   userInfo:@{NSLocalizedDescriptionKey: @"无效的下载链接"}];
        if (outError) *outError = invalidURLError;
        if (taskId) [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:invalidURLError];
        return NO;
    }

    PLDownloadRequest *request = [PLDownloadRequest new];
    request.candidateURLs = [PLMirrorCenter candidateURLsForOriginalURL:url resourceType:resourceType];
    request.destinationPath = destPath;
    // taskIdentifier 留空：PLDownloadClient 按 destinationPath + 首 URL 稳定派生断点续传键
    request.allowZipFallbackCheck = YES; // 仅对 .zip/.jar 生效（installer.jar 兜底校验）

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    __block NSError *blockError = nil;
    __block int64_t receivedBytes = 0; // 仅在本操作的串行回调线程访问，无需加锁

    [[PLDownloadClient sharedClient] startRequest:request
                                         progress:^(int64_t deltaBytes, int64_t totalExpectedBytes) {
        if (!taskId) return;
        receivedBytes += deltaBytes; // 含负 delta 回退，直接累加
        double fraction = (totalExpectedBytes > 0) ? (double)receivedBytes / (double)totalExpectedBytes : 0.0;
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                     progress:MIN(MAX(fraction, 0.0), 1.0)
                                                   totalBytes:totalExpectedBytes
                                              downloadedBytes:MAX(receivedBytes, 0)];
    }
                                            speed:nil
                                       completion:^(BOOL success, NSError *error) {
        ok = success;
        blockError = error;
        dispatch_semaphore_signal(sema);
    }];

    // 阻塞调用线程（后台线程）直至完成——同步门面语义
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    if (taskId) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:(ok ? nil : blockError)];
    }
    if (!ok && outError) *outError = blockError;
    return ok;
}

#pragma mark - Task 3.2：404/NotFound 识别

/// 判断下载错误是否为"资源不存在"（HTTP 404 / NotFound）。
/// PLDownloadClient 对非 2xx 响应构造 "HTTP 404（<url>）" 描述（PLDownloadClientErrorDomain）；
/// 全部候选耗尽时聚合错误（code = AllCandidatesExhausted）的
/// userInfo[PLDownloadClientUnderlyingErrorsKey] 携带各候选的底层错误。
/// 聚合错误下需全部候选均为 404 才判定为资源不存在——否则视为普通网络失败进失败列表，
/// 以保留换源重试的价值。
- (BOOL)isResourceNotFoundError:(NSError *)error {
    if (!error) return NO;
    NSArray *underlying = error.userInfo[PLDownloadClientUnderlyingErrorsKey];
    if ([underlying isKindOfClass:[NSArray class]] && underlying.count > 0) {
        for (id sub in underlying) {
            if (![sub isKindOfClass:[NSError class]]) return NO;
            if (![self isSingleNotFoundError:(NSError *)sub]) return NO;
        }
        return YES;
    }
    return [self isSingleNotFoundError:error];
}

/// 单个错误是否为 404/NotFound。
/// 只匹配 "HTTP 404" 前缀格式与 "Not Found" 字样，不匹配裸 "404"——
/// 否则 URL 片段中的 "404" 字样（如 fileID）会造成误判。
- (BOOL)isSingleNotFoundError:(NSError *)error {
    if (!error) return NO;
    NSString *desc = error.localizedFailureReason ?: error.localizedDescription ?: @"";
    if ([desc rangeOfString:@"HTTP 404"].location != NSNotFound) return YES;
    if ([desc rangeOfString:@"Not Found" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

/// 阶段5修复（参照 FCL CurseForgeFileResolver）：当整合包 manifest 中缺失 fileName 时，
/// 通过 BMCLAPI 的下载链接做 HEAD 请求，跟随重定向到 CurseForge CDN 的实际文件 URL，
/// 取其 lastPathComponent 作为真实文件名（如 "jei-1.20.1-15.2.0.27.jar"）。
/// 这避免了将文件保存为 "12345-67890.jar" 这种用户无法识别的 fallback 名称。
/// 失败时返回 nil，由调用方继续使用 fallback。
- (nullable NSString *)fetchCurseForgeRealFileName:(long long)projectID fileID:(long long)fileID {
    NSString *bmclDownloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/curseforge/files/%lld/%lld/download", projectID, fileID];
    NSURL *url = [NSURL URLWithString:bmclDownloadURL];
    if (!url) return nil;

    // 使用临时 NSURLSession 不跟随重定向（手工处理），便于拿到 Location 头
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15;
    cfg.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        @"Accept": @"*/*"
    };
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"HEAD";

    __block NSString *resolvedName = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            // 优先取 Content-Disposition 头中的 filename（最权威）
            NSString *contentDisposition = http.allHeaderFields[@"Content-Disposition"];
            if ([contentDisposition isKindOfClass:[NSString class]] && contentDisposition.length > 0) {
                NSRange fnRange = [contentDisposition rangeOfString:@"filename=\""
                                                            options:NSCaseInsensitiveSearch];
                if (fnRange.location != NSNotFound) {
                    NSUInteger start = fnRange.location + fnRange.length;
                    NSUInteger end = [contentDisposition rangeOfString:@"\"" options:0 range:NSMakeRange(start, contentDisposition.length - start)].location;
                    if (end != NSNotFound && end > start) {
                        resolvedName = [contentDisposition substringWithRange:NSMakeRange(start, end - start)];
                    }
                }
            }
            // 没拿到 Content-Disposition，尝试从最终 URL 的 lastPathComponent 取
            if (!resolvedName && http.URL) {
                NSString *last = http.URL.lastPathComponent;
                if (last.length > 0 && ![last isEqualToString:@"download"]) {
                    resolvedName = last;
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (waitResult != 0) {
        [task cancel];
    }
    [session finishTasksAndInvalidate];
    return resolvedName;
}

/// 安装模组加载器
/// Fabric/Quilt: 拉取 profile json 并写入 versions/<id>/<id>.json
/// Forge/NeoForge: 写一个最小的版本 JSON 占位 (依赖用户后续手动安装)
///                或者引导用户安装。这里先写占位，避免 profile 引用不存在的版本时崩溃
- (BOOL)installModLoader:(NSString *)loader
          loaderVersion:(NSString *)loaderVersion
         minecraftVersion:(NSString *)minecraftVersion
                versionId:(NSString *)versionId
          gameDirAbsolute:(NSString *)gameDirAbsolute
                   error:(NSError **)error {
    if (!loaderVersion || loaderVersion.length == 0 || !minecraftVersion || minecraftVersion.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4001
                                     userInfo:@{NSLocalizedDescriptionKey: @"缺少加载器版本或游戏版本"}];
        }
        return NO;
    }

    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    // 版本 JSON 必须写入 POJAV_GAME_DIR/versions/（主目录），而非 gameDirAbsolute（整合包隔离目录）。
    // Minecraft 启动器 Java 端 Tools.java 的 DIR_HOME_VERSION 固定指向 POJAV_GAME_DIR/versions，
    // 不从 profile gameDir 读取。之前写入 gameDirAbsolute/versions/ 会导致启动时"找不到版本信息"。
    // gameDirAbsolute 仅用于 mods/saves/configs 等用户数据隔离（通过 profile gameDir=user.dir 实现）。
    NSString *mainVersionDir = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    NSString *versionDir = mainVersionDir;
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Fabric/Quilt: 直接从 meta API 拉 profile json
    if ([loader isEqualToString:@"Fabric"] || [loader isEqualToString:@"Quilt"]) {
        NSDictionary *endpoints = FabricUtils.endpoints[loader];
        NSString *jsonURLTemplate = endpoints[@"json"];
        if (!jsonURLTemplate) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackImportError"
                                             code:4002
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ endpoints 未找到", loader]}];
            }
            return NO;
        }
        NSString *jsonURL = [NSString stringWithFormat:jsonURLTemplate, minecraftVersion, loaderVersion];
        NSURL *url = [NSURL URLWithString:jsonURL];
        // 阶段5修复：构造出的 URL 可能因 loaderVersion 含非法字符导致 URLWithString: 返回 nil，
        // downloadTaskWithURL:nil 会崩溃。此处显式判断并返回明确错误。
        if (!url) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackImportError"
                                             code:4002
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ profile JSON URL 非法: %@", loader, jsonURL]}];
            }
            return NO;
        }

        NSString *displayName = [NSString stringWithFormat:@"%@ %@ profile", loader, loaderVersion];
        // Phase 3：底层下载改由 PLDownloadClient 接管（rawTask=nil），镜像候选按 ModLoader
        // 体系（BMCLAPI）重写；下载失败/重试由其内部处理，本方法仅同步等待结果。
        DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
            registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                            resourceName:versionId
                             displayName:displayName
                          downloadSource:downloadSource
                                 rawTask:nil
                          supportsResume:NO
                                 iconURL:nil];
        [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];

        NSError *dlError = nil;
        if (![self downloadFileFromURL:jsonURL toPath:versionJsonPath taskId:taskItem.taskId resourceType:PLMirrorResourceTypeModLoader error:&dlError]) {
            if (error) *error = dlError;
            return NO;
        }
        return YES;
    }

    // Forge/NeoForge: 下载 installer.jar 并调用直装器写入 modpack 的 gameDir
    // 直装器会写完整的 version.json（含正确的 mainClass、arguments、libraries）+ 下载 Forge 库
    // 这样整合包启动时能正确加载 Forge，不再因占位 JSON 缺库/缺参数而崩溃
    NSString *installerURL = [self buildInstallerURLForLoader:loader
                                               loaderVersion:loaderVersion
                                              minecraftVersion:minecraftVersion];
    if (!installerURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4003
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法构造 %@ installer URL", loader]}];
        }
        return NO;
    }

    // 下载 installer.jar 到临时目录
    NSString *tmpInstallerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"%@-installer.jar", versionId]];

    NSString *installerDisplayName = [NSString stringWithFormat:@"%@ %@ installer", loader, loaderVersion];
    // Phase 3：底层下载改由 PLDownloadClient 接管（rawTask=nil），镜像候选按 ModLoader
    // 体系（BMCLAPI maven）重写；URL 非法检查移入 downloadFileFromURL 内部统一处理。
    DownloadTaskItem *installerItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                        resourceName:versionId
                         displayName:installerDisplayName
                      downloadSource:downloadSource
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    [[DownloadTaskManager sharedManager] setTaskWithId:installerItem.taskId state:DownloadTaskStateDownloading];
    NSString *installerTaskId = installerItem.taskId;

    NSError *dlError = nil;
    if (![self downloadFileFromURL:installerURL toPath:tmpInstallerPath taskId:installerTaskId resourceType:PLMirrorResourceTypeModLoader error:&dlError]) {
        // installer.jar 下载失败：写显式失败的占位 JSON（mainClass 指向不存在的类，启动时会显式报错，
        // 避免误装作 vanilla MC 让用户以为 mods 生效）
        NSLog(@"[ModpackImport] %@ installer.jar download failed, falling back to placeholder JSON: %@", loader, installerURL);
        NSInteger javaMajor = [self javaMajorVersionForMC:minecraftVersion];
        NSDictionary *placeholderJSON = @{
            @"_comment_": [NSString stringWithFormat:@"此整合包需要 %@ %@ 加载器，自动安装失败。请通过下载界面手动安装。", loader, loaderVersion],
            @"id": versionId,
            @"inheritsFrom": minecraftVersion,
            @"type": @"release",
            @"mainClass": @"net.angelaura.installer.MissingLoader",  // 故意指向不存在的类，启动时显式报错
            @"javaVersion": @{@"component": @"java-runtime", @"majorVersion": @(javaMajor)}
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:placeholderJSON options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportService" code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ installer.jar 下载失败，已写入占位 JSON。请手动安装加载器。", loader]}];
        }
        return NO;  // 让调用方感知失败并打印警告
    }

    NSLog(@"[ModpackImport] %@ installer.jar download completed: %@", loader, tmpInstallerPath);

    // 调用直装器，写入 modpack 的 gameDirAbsolute（不注册 profile，由 createProfileForModpack 统一注册）
    NSError *installError = nil;
    BOOL installSuccess = NO;
    if ([loader isEqualToString:@"NeoForge"]) {
        installSuccess = [NeoForgeDirectInstaller installNeoForgeFromInstaller:tmpInstallerPath
                                                                     versionId:versionId
                                                                 customGameDir:gameDirAbsolute
                                                           skipRegisterVersion:YES
                                                                      progress:nil
                                                                         error:&installError];
    } else {
        // Forge
        installSuccess = [ForgeDirectInstaller installForgeFromInstaller:tmpInstallerPath
                                                               versionId:versionId
                                                           customGameDir:gameDirAbsolute
                                                     skipRegisterVersion:YES
                                                                progress:nil
                                                                   error:&installError];
    }

    // 清理临时 installer.jar
    [[NSFileManager defaultManager] removeItemAtPath:tmpInstallerPath error:nil];

    if (!installSuccess) {
        NSLog(@"[ModpackImport] %@ direct install failed, falling back to placeholder JSON: %@", loader, installError.localizedDescription);
        // 使用外层作用域的 installerTaskId（installerItem 仅在 floatingBallEnabled 块内声明）
        if (installerTaskId) {
            [[DownloadTaskManager sharedManager] setTaskWithId:installerTaskId completedWithError:installError];
        }
        // 直装失败：写显式失败的占位 JSON（mainClass 指向不存在的类，启动时会显式报错，
        // 避免误装作 vanilla MC 让用户以为 mods 生效）
        NSInteger javaMajor = [self javaMajorVersionForMC:minecraftVersion];
        NSDictionary *placeholderJSON = @{
            @"_comment_": [NSString stringWithFormat:@"此整合包需要 %@ %@ 加载器，自动安装失败：%@。请通过下载界面手动安装。", loader, loaderVersion, installError.localizedDescription ?: @"未知错误"],
            @"id": versionId,
            @"inheritsFrom": minecraftVersion,
            @"type": @"release",
            @"mainClass": @"net.angelaura.installer.MissingLoader",  // 故意指向不存在的类，启动时显式报错
            @"javaVersion": @{@"component": @"java-runtime", @"majorVersion": @(javaMajor)}
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:placeholderJSON options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportService" code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ 直装失败：%@。已写入占位 JSON。请手动安装加载器。", loader, installError.localizedDescription ?: @"未知错误"]}];
        }
        return NO;  // 让调用方感知失败并打印警告
    }

    NSLog(@"[ModpackImport] %@ direct install succeeded, version.json written to: %@", loader, versionJsonPath);
    return YES;
}

/// 阶段5修复（参照 FCL ModpackHelper.ensureCompleteVersion）：
/// 整合包导入时，installModLoader 只写入了 loader 的 version.json（Fabric profile json
/// 或 Forge 直装器输出的 version.json），但父版本（原版 MC）的 version.json、libraries、
/// assets 都还没下载。之前用户启动整合包时会报"找不到 net.minecraft.client.main.Main"
/// 或 "找不到 libraries"等错误，正是因为这一步缺失。
///
/// 本方法：
/// 1. 确保父版本 JSON 存在（复用 ForgeDirectInstaller.ensureParentVersionExists:，
///    该方法通用，不依赖 Forge 特定逻辑，对 Fabric/Quilt/原版同样适用）
/// 2. 创建 MinecraftResourceDownloadTask 触发完整版本下载（libraries + assets），
///    downloadVersion: 内部会处理 inheritsFrom，对已存在且 SHA1 正确的文件自动跳过
/// 3. 用 KVO + dispatch_semaphore 同步等待下载完成，向上层报告进度
- (BOOL)ensureCompleteVersionInstalled:(NSString *)versionId
                       minecraftVersion:(NSString *)minecraftVersion
                              progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                                 error:(NSError **)error {
    if (!versionId || versionId.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4005
                                     userInfo:@{NSLocalizedDescriptionKey: @"versionId 为空，无法安装完整版本"}];
        }
        return NO;
    }

    NSLog(@"[ModpackImport] Ensuring complete version is installed: %@ (parent version: %@)", versionId, minecraftVersion ?: @"(none)");

    // 第 1 步：确保父版本 JSON 存在（仅当 loader version JSON 含 inheritsFrom 时需要）
    // 这里无条件调用 ensureParentVersionExists:，它内部会检查 JSON 是否已存在并跳过。
    if (minecraftVersion.length > 0) {
        NSError *parentError = nil;
        BOOL parentOK = [ForgeDirectInstaller ensureParentVersionExists:minecraftVersion error:&parentError];
        if (!parentOK) {
            NSLog(@"[ModpackImport] Warning: Parent version %@ JSON download failed: %@",
                  minecraftVersion, parentError.localizedDescription);
            // 不直接 fail：downloadVersion: 内部也会检查父版本，若已存在则继续
            // 只有当父版本 JSON 真的不存在时才会 fail
        }
    }

    if (progress) progress(0.88, [NSString stringWithFormat:@"正在下载 %@ 的游戏文件", versionId]);

    // 第 2 步：创建 MinecraftResourceDownloadTask 触发完整下载
    // 不注册到 DownloadTaskManager（整合包导入已有自己的进度卡片，避免重复显示）
    MinecraftResourceDownloadTask *downloader = [MinecraftResourceDownloadTask new];
    downloader.maxRetryCount = 3;

    // 同步等待：用轮询检查 progress.finished，避免 KVO 悬空问题
    // （downloadVersion: 内部的 prepareForDownload 会重建 self.progress，
    //   若在调用前 addObserver，observe 的是旧对象，新 progress 完成时不会触发回调）
    __block BOOL errorOccurred = NO;
    __block NSString *failReason = nil;

    // downloader.handleError 在下载流程出错时调用（finishDownloadWithErrorString: 内）
    downloader.handleError = ^{
        @synchronized(self) {
            errorOccurred = YES;
            failReason = @"下载流程出错（见日志）";
        }
    };

    // 启动下载（downloadVersion: 是异步的，内部会 prepareForDownload 重建 progress）
    NSDictionary *versionArg = @{@"id": versionId};
    [downloader downloadVersion:versionArg];

    // 轮询等待完成（每 0.5s 检查一次，最长 30 分钟）
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30 * 60];
    BOOL downloadSucceeded = NO;
    while ([deadline timeIntervalSinceNow] > 0) {
        // 检查错误
        @synchronized(self) {
            if (errorOccurred) {
                break;
            }
        }
        // 检查 progress 完成度（每次访问 downloader.progress 都是最新的）
        NSProgress *currentProg = downloader.progress;
        if (currentProg && currentProg.finished) {
            downloadSucceeded = !currentProg.cancelled;
            break;
        }
        // 检查取消信号
        if (self.cancelled) {
            if (currentProg) [currentProg cancel];
            break;
        }
        [NSThread sleepForTimeInterval:0.5];
    }

    // 最终状态检查
    NSProgress *finalProg = downloader.progress;
    if (finalProg && finalProg.finished && !finalProg.cancelled) {
        downloadSucceeded = YES;
    } else if (finalProg && !finalProg.finished) {
        // 超时
        [finalProg cancel];
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4006
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"下载 %@ 游戏文件超时（30 分钟）", versionId]}];
        }
        return NO;
    }

    @synchronized(self) {
        if (errorOccurred) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackImportError"
                                             code:4007
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"下载 %@ 游戏文件失败: %@", versionId, failReason ?: @"未知错误"]}];
            }
            return NO;
        }
    }

    if (!downloadSucceeded) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4007
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"下载 %@ 游戏文件失败", versionId]}];
        }
        return NO;
    }

    NSLog(@"[ModpackImport] Full version download completed: %@", versionId);

    // 阶段5修复：即使 progress 完成，也可能有部分库/资源文件下载失败（记录在 downloader.failedFiles）
    // 将这些失败文件汇总到 ModpackImportService.failedFiles，让上层向用户展示
    NSArray<NSDictionary *> *versionFailedFiles = [downloader.failedFiles copy];
    if (versionFailedFiles.count > 0) {
        NSLog(@"[ModpackImport] Warning: Version %@ has %lu files that failed to download",
              versionId, (unsigned long)versionFailedFiles.count);
        @synchronized(self) {
            for (NSDictionary *f in versionFailedFiles) {
                [self.failedFilesInternal addObject:@{
                    @"fileName": [NSString stringWithFormat:@"%@: %@", versionId, f[@"name"] ?: @"(unknown)"],
                    @"url": @"",
                    @"reason": f[@"error"] ?: @"下载失败",
                    @"format": @"version"
                }];
            }
        }
    }

    return YES;
}

/// 根据 loader 类型构造 installer.jar 下载 URL
/// Forge: https://maven.minecraftforge.net/net/minecraftforge/forge/<mc>-<loader>/forge-<mc>-<loader>-installer.jar
/// NeoForge 1.20.1: https://maven.neoforged.net/releases/net/neoforged/forge/<loader>/forge-<loader>-installer.jar
/// NeoForge 其他: https://maven.neoforged.net/releases/net/neoforged/neoforge/<loader>/neoforge-<loader>-installer.jar
/// BMCLAPI 镜像优先（若用户选了 bmclapi 源）
- (nullable NSString *)buildInstallerURLForLoader:(NSString *)loader
                                    loaderVersion:(NSString *)loaderVersion
                                   minecraftVersion:(NSString *)minecraftVersion {
    NSString *downloadSource = [PLPreferences currentDownloadSourceForType:@"forge"];
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    if ([loader isEqualToString:@"Forge"]) {
        // Forge versionString = "<mc>-<loaderVersion>"，例如 "1.20.1-47.3.0"
        NSString *versionString = [NSString stringWithFormat:@"%@-%@", minecraftVersion, loaderVersion];
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/minecraftforge/forge/%@/forge-%@-installer.jar", versionString, versionString];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/net/minecraftforge/forge/%@/forge-%@-installer.jar", versionString, versionString];
    }

    if ([loader isEqualToString:@"NeoForge"]) {
        // NeoForge 1.20.1 早期版本 artifactId 是 net.neoforged:forge，之后是 net.neoforged:neoforge
        // loaderVersion 例如 "47.1.0"（1.20.1）或 "20.6.119-beta"（1.20.6+）
        BOOL isLegacyForgeArtifact = [minecraftVersion isEqualToString:@"1.20.1"];
        if (isLegacyForgeArtifact) {
            if (useBMCLAPI) {
                return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/neoforged/forge/%@/forge-%@-installer.jar", loaderVersion, loaderVersion];
            }
            return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/forge/%@/forge-%@-installer.jar", loaderVersion, loaderVersion];
        }
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", loaderVersion, loaderVersion];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", loaderVersion, loaderVersion];
    }

    return nil;
}

/// 根据 MC 版本推断所需 Java 主版本号
/// 1.20.5+ → 21, 1.18+ → 17, 1.17 → 17（项目未捆绑 Java 16，Java 17 可向后兼容），1.16.5- → 8
- (NSInteger)javaMajorVersionForMC:(NSString *)mcVersion {
    NSArray *parts = [mcVersion componentsSeparatedByString:@"."];
    if (parts.count < 2) return 8;
    NSInteger major = [parts[1] integerValue];
    if (major >= 21) return 21;       // 1.21+
    if (major >= 20 && parts.count >= 3 && [parts[2] integerValue] >= 5) return 21; // 1.20.5+
    if (major >= 18) return 17;       // 1.18+
    if (major >= 17) return 17;       // 1.17（项目未捆绑 Java 16，Java 17 可向后兼容运行 1.17）
    return 8;                          // 1.16.5 及以下
}

- (nullable NSString *)createProfileForModpack:(NSDictionary *)modpackInfo
                              gameDirRelative:(NSString *)gameDirRelative
                                    versionId:(NSString *)versionId
                                        error:(NSError **)error {
    NSString *name = modpackInfo[@"name"];
    NSString *modpackId = modpackInfo[@"id"];

    // 修复（参照 FCL/HMCL）：profile name 优先使用整合包可读名（name 字段），
    // 仅在重名时回退到 modpackId 避免冲突。原实现直接用 modpackId 作为 profile name，
    // 导致用户在版本列表看到 UUID 而非整合包名。
    NSString *profileName = name.length > 0 ? name : modpackId;
    // 重名冲突时追加序号
    if (PLProfiles.current.profiles[profileName]) {
        NSInteger suffix = 2;
        NSString *baseName = profileName;
        while (PLProfiles.current.profiles[profileName]) {
            profileName = [NSString stringWithFormat:@"%@ (%ld)", baseName, (long)suffix];
            suffix++;
        }
    }

    NSMutableDictionary *profile = [@{
        @"name": name.length > 0 ? name : profileName,
        @"lastVersionId": versionId ?: @"",
        @"gameDir": gameDirRelative,
        @"created": [self iso8601StringFromDate:[NSDate date]],
        @"type": @"modpack"
    } mutableCopy];

    // 修复（参照 FCL/HMCL）：写入 javaVersion 字段
    // MC 1.18+ 需要 Java 17，1.20.5+ 需要 Java 21，1.16.5- 用 Java 8
    // 不写此字段时启动器可能用默认 Java 8 启动 MC 1.18+ 导致崩溃
    NSString *mcVersion = modpackInfo[@"minecraftVersion"];
    if (mcVersion.length > 0) {
        NSInteger javaMajor = [self javaMajorVersionForMC:mcVersion];
        profile[@"javaVersion"] = @{
            @"component": @"java-runtime",
            @"majorVersion": @(javaMajor)
        };
    }

    NSString *iconBase64 = modpackInfo[@"iconBase64"];
    if (iconBase64.length > 0) {
        profile[@"icon"] = iconBase64;
    }

    PLProfiles.current.profiles[profileName] = profile;
    [PLProfiles.current save];

    return profileName;
}

#pragma mark - Get Imported Modpacks

- (NSArray<NSDictionary *> *)getImportedModpacks {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *modpacks = [defaults objectForKey:kImportedModpacksKey];
    return modpacks ?: @[];
}

- (void)saveImportedModpack:(NSDictionary *)modpackInfo {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *modpacks = [[self getImportedModpacks] mutableCopy];
    [modpacks addObject:modpackInfo];
    [defaults setObject:modpacks forKey:kImportedModpacksKey];
    [defaults synchronize];
}

#pragma mark - Delete Modpack

- (BOOL)deleteModpack:(NSDictionary *)modpackInfo error:(NSError **)error {
    NSString *gameDirAbsolute = modpackInfo[@"gameDirAbsolute"];
    if (!gameDirAbsolute) {
        // 兼容旧数据: 尝试从 modpackDir 字段获取
        gameDirAbsolute = modpackInfo[@"modpackDir"];
    }
    NSString *profileName = modpackInfo[@"profileName"];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (gameDirAbsolute && [fm fileExistsAtPath:gameDirAbsolute]) {
        if (![fm removeItemAtPath:gameDirAbsolute error:error]) {
            return NO;
        }
    }

    if (profileName) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        [PLProfiles.current save];
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *modpacks = [[self getImportedModpacks] mutableCopy];

    NSUInteger index = [modpacks indexOfObjectPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
        return [obj[@"id"] isEqualToString:modpackInfo[@"id"]];
    }];

    if (index != NSNotFound) {
        [modpacks removeObjectAtIndex:index];
        [defaults setObject:modpacks forKey:kImportedModpacksKey];
        [defaults synchronize];
    }

    return YES;
}

@end
