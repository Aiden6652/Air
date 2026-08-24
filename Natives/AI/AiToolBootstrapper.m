//
//  AiToolBootstrapper.m
//  Amethyst
//

#import "AiToolBootstrapper.h"
#import "AiToolRegistry.h"

#import "AiInstancesTool.h"
#import "AiLogReader.h"
#import "AiCrashAnalyzer.h"
#import "AiFileTools.h"
#import "AiAskTool.h"
#import "AiAssetTools.h"

@implementation AiToolBootstrapper

+ (void)registerBuiltinTools {
    AiToolRegistry *registry = [AiToolRegistry sharedRegistry];

    // ===== 3a 阶段内置工具 =====

    // 实例/版本工具（list_instances、list_game_versions）
    [registry registerTool:[[AiInstancesTool alloc] initWithName:@"list_instances"]];
    [registry registerTool:[[AiInstancesTool alloc] initWithName:@"list_game_versions"]];

    // 日志读取工具（read_latest_log、read_crash_report）
    [registry registerTool:[[AiLogReader alloc] initWithName:@"read_latest_log"]];
    [registry registerTool:[[AiLogReader alloc] initWithName:@"read_crash_report"]];

    // 崩溃分析工具（match_known_errors）
    [registry registerTool:[[AiCrashAnalyzer alloc] init]];

    // 文件工具（list_files、read_file、grep_files、write_file、edit_file、delete_file）
    [registry registerTool:[[AiFileTools alloc] initWithName:@"list_files"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"read_file"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"grep_files"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"write_file"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"edit_file"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"delete_file"]];

    // 交互问答工具（ask）
    [registry registerTool:[[AiAskTool alloc] init]];

    // ===== 以下为 3b 资源工具 =====

    // Modrinth 搜索工具（ExternalNetwork）
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_mods"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_resourcepacks"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_shaders"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_datapacks"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_modpacks"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_worlds"]];

    // 资源安装 / 加载器工具（ControlledWrite）
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_mod"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_resourcepack"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_shader"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_datapack"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_game_version"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_loader"]];
}

@end