//
//  ModpackImportViewController.m
//  Amethyst
//
//  参照 FCL ModpackImportScreen / HMCL ModpackProviderPane / ZL2 ModpackImportScreen 重做
//
//  设计要点：
//    1. 顶部使用 UISegmentedControl 切换 "导入 / 导出"，导出切换时 push 到独立的 ModpackExportViewController
//    2. 导入流程：选择文件 → 解析（轻量 HUD）→ 预览卡片（mod 信息）→ 导入（统一进度页，自动弹出）→ 完成提示
//    3. redesign-download-ui Phase 5 Task 5.1：删除自定义 FCL 风格进度卡片，导入进度由
//       ModpackImportService 注册 DownloadTaskManager 主任务（6 阶段 + autoPresentDetail）驱动
//       PLTaskProgressViewController 统一进度页展示；取消经由统一进度页"取消"按钮 →
//       DownloadTaskManager 置主任务 Cancelled → service 轮询感知（checkCancelledWithError）
//    4. 已导入整合包列表使用现代化的卡片样式
//

#import "ModpackImportViewController.h"
#import "BackgroundManager.h"
#import "ModpackImportService.h"
#import "ModpackExportViewController.h"
#import "PLProfiles.h"
#import "UnzipKit.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ModpackImportViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UISegmentedControl *tabSegment;       // 顶部 "导入 | 导出" 切换
@property (nonatomic, strong) UIView *headerContainerView;          // 顶部说明 + 选择文件按钮
@property (nonatomic, strong) UILabel *hintLabel;                   // 支持格式说明
@property (nonatomic, strong) UIButton *importButton;               // 主导入按钮
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *importedModpacks;
@property (nonatomic, strong) ModpackImportService *importService;
@property (nonatomic, strong) NSDictionary *currentImportingModpack;

// 轻量加载 HUD（仅解析/删除等本地短操作使用；导入进度走统一进度页）
@property (nonatomic, strong) UIView *loadingOverlay;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UILabel *loadingLabel;
@end

@implementation ModpackImportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.title = @"整合包";

    [[BackgroundManager sharedManager] applyEffectToView:self.view];

    self.importService = [[ModpackImportService alloc] init];
    self.importedModpacks = [NSMutableArray array];

    [self setupNavigationTab];
    [self setupUI];
    [self loadImportedModpacks];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 回到导入页时，确保 tab 显示"导入"
    self.tabSegment.selectedSegmentIndex = 0;
}

#pragma mark - 顶部 Tab 切换（导入 / 导出）

- (void)setupNavigationTab {
    self.tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"导入", @"导出"]];
    self.tabSegment.selectedSegmentIndex = 0;
    [self.tabSegment addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];

    // 放置在 navigationItem.titleView，宽度自适应
    CGSize fittingSize = [self.tabSegment sizeThatFits:CGSizeMake(220, 30)];
    self.tabSegment.frame = CGRectMake(0, 0, MAX(180, fittingSize.width), 30);
    self.navigationItem.titleView = self.tabSegment;
}

- (void)tabChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex == 1) {
        // 切换到导出：push 到 ModpackExportViewController
        ModpackExportViewController *exportVC = [[ModpackExportViewController alloc] init];
        exportVC.preselectedProfileName = PLProfiles.current.selectedProfileName;
        [self.navigationController pushViewController:exportVC animated:YES];
        // 立即把 tab 切回"导入"，因为返回时 viewWillAppear 会重置
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.selectedSegmentIndex = 0;
        });
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // 顶部说明 + 选择文件按钮容器
    self.headerContainerView = [[UIView alloc] init];
    self.headerContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerContainerView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.headerContainerView];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.text = @"支持格式：Modrinth (.mrpack)、CurseForge (.zip)、MCBBS、MMC (MultiMC/Prism)、Plain ZIP（直接含 .minecraft）";
    [self.headerContainerView addSubview:self.hintLabel];

    self.importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.importButton setTitle:@"  选择整合包文件" forState:UIControlStateNormal];
    [self.importButton setImage:[UIImage systemImageNamed:@"doc.badge.plus"] forState:UIControlStateNormal];
    self.importButton.backgroundColor = [UIColor systemBlueColor];
    [self.importButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.importButton.tintColor = [UIColor whiteColor];
    self.importButton.layer.cornerRadius = 12;
    self.importButton.layer.masksToBounds = YES;
    self.importButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.importButton addTarget:self action:@selector(selectModpackFile) forControlEvents:UIControlEventTouchUpInside];
    [self.headerContainerView addSubview:self.importButton];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"ModpackCell"];
    self.tableView.rowHeight = 80;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.text = @"还没有导入的整合包\n点击上方按钮导入";
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerContainerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.headerContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.headerContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.hintLabel.topAnchor constraintEqualToAnchor:self.headerContainerView.topAnchor],
        [self.hintLabel.leadingAnchor constraintEqualToAnchor:self.headerContainerView.leadingAnchor],
        [self.hintLabel.trailingAnchor constraintEqualToAnchor:self.headerContainerView.trailingAnchor],

        [self.importButton.topAnchor constraintEqualToAnchor:self.hintLabel.bottomAnchor constant:10],
        [self.importButton.leadingAnchor constraintEqualToAnchor:self.headerContainerView.leadingAnchor],
        [self.importButton.trailingAnchor constraintEqualToAnchor:self.headerContainerView.trailingAnchor],
        [self.importButton.heightAnchor constraintEqualToConstant:50],
        [self.importButton.bottomAnchor constraintEqualToAnchor:self.headerContainerView.bottomAnchor],

        [self.tableView.topAnchor constraintEqualToAnchor:self.headerContainerView.bottomAnchor constant:12],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

#pragma mark - 轻量加载 HUD（解析/删除等本地短操作）

- (void)showLoadingHUD:(NSString *)title {
    [self hideLoadingHUD];

    UIView *overlay = [[UIView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
    overlay.userInteractionEnabled = YES;
    [self.view addSubview:overlay];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.color = [UIColor whiteColor];
    spinner.hidesWhenStopped = NO;
    [spinner startAnimating];
    [overlay addSubview:spinner];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    [overlay addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [spinner.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor constant:-24],

        [label.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:12],
        [label.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [label.widthAnchor constraintLessThanOrEqualToConstant:260]
    ]];

    self.loadingOverlay = overlay;
    self.loadingSpinner = spinner;
    self.loadingLabel = label;
}

- (void)hideLoadingHUD {
    if (self.loadingOverlay) {
        [self.loadingSpinner stopAnimating];
        [self.loadingOverlay removeFromSuperview];
        self.loadingOverlay = nil;
        self.loadingSpinner = nil;
        self.loadingLabel = nil;
    }
}

- (void)loadImportedModpacks {
    NSArray *modpacks = [self.importService getImportedModpacks];
    [self.importedModpacks removeAllObjects];
    [self.importedModpacks addObjectsFromArray:modpacks];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.emptyLabel.hidden = self.importedModpacks.count > 0;
        [self.tableView reloadData];
    });
}

#pragma mark - 文件选择

- (void)selectModpackFile {
    NSArray<UTType *> *contentTypes = @[
        [UTType typeWithFilenameExtension:@"mrpack"],
        [UTType typeWithFilenameExtension:@"zip"]
    ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *fileURL = urls.firstObject;
    NSString *fileExtension = fileURL.pathExtension.lowercaseString;

    if (![fileExtension isEqualToString:@"mrpack"] && ![fileExtension isEqualToString:@"zip"]) {
        [self showAlertWithTitle:@"无效的文件" message:@"请选择 .mrpack 或 .zip 文件"];
        return;
    }

    BOOL accessGranted = [fileURL startAccessingSecurityScopedResource];
    if (!accessGranted) {
        [self showAlertWithTitle:@"访问被拒绝" message:@"无法访问选中的文件"];
        return;
    }

    // 解析阶段：轻量 HUD（本地 zip 读取，通常 < 1s）
    [self showLoadingHUD:@"正在解析整合包..."];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        NSDictionary *modpackInfo = nil;

        @try {
            modpackInfo = [self.importService parseModpackAtURL:fileURL error:&error];
        } @catch (NSException *exception) {
            error = [NSError errorWithDomain:@"ModpackImportError" code:9999
                                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"解析异常: %@", exception.reason]}];
        }

        [fileURL stopAccessingSecurityScopedResource];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !modpackInfo) {
                [self hideLoadingHUD];
                [self showAlertWithTitle:@"解析失败" message:error.localizedDescription ?: @"无法解析整合包文件"];
                return;
            }
            self.currentImportingModpack = modpackInfo;
            [self hideLoadingHUD];
            [self showModpackPreview:modpackInfo fileURL:fileURL];
        });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {}

#pragma mark - 整合包预览卡片（参照 FCL ModpackPreviewSheet / HMCL ModpackInfoPage）

- (void)showModpackPreview:(NSDictionary *)modpackInfo fileURL:(NSURL *)fileURL {
    NSString *name = modpackInfo[@"name"] ?: @"未知";
    NSString *version = modpackInfo[@"version"] ?: @"未知";
    NSString *author = modpackInfo[@"author"] ?: @"";
    NSString *mcVersion = modpackInfo[@"minecraftVersion"] ?: @"未知";
    NSString *loader = modpackInfo[@"loader"] ?: @"Vanilla";
    NSString *loaderVersion = modpackInfo[@"loaderVersion"] ?: @"";
    NSString *format = modpackInfo[@"format"] ?: @"unknown";
    NSNumber *modCountNum = modpackInfo[@"modCount"];
    NSNumber *fileCountNum = modpackInfo[@"fileCount"];
    NSString *fileName = fileURL.lastPathComponent ?: @"";

    // 格式映射成中文
    NSDictionary *formatLabels = @{
        @"modrinth": @"Modrinth (.mrpack)",
        @"curseforge": @"CurseForge (.zip)",
        @"mcbbs": @"MCBBS (社区标准)",
        @"mmc": @"MMC (MultiMC/Prism)",
        @"plainzip": @"Plain ZIP (.minecraft)"
    };
    NSString *formatLabel = formatLabels[format] ?: format;

    NSMutableString *message = [NSMutableString string];
    [message appendFormat:@"文件: %@\n", fileName];
    [message appendFormat:@"格式: %@\n", formatLabel];
    [message appendFormat:@"名称: %@\n", name];
    [message appendFormat:@"版本: %@", version];
    if (author.length > 0) {
        [message appendFormat:@"   作者: %@", author];
    }
    [message appendString:@"\n"];
    [message appendFormat:@"Minecraft: %@\n", mcVersion];
    [message appendFormat:@"加载器: %@", loader];
    if (loaderVersion.length > 0) {
        [message appendFormat:@" %@", loaderVersion];
    }
    [message appendString:@"\n"];

    if (modCountNum && modCountNum.integerValue > 0) {
        [message appendFormat:@"需下载模组: %ld 个\n", (long)modCountNum.integerValue];
    }
    if (fileCountNum && fileCountNum.integerValue > 0) {
        [message appendFormat:@"需解压文件: %ld 个\n", (long)fileCountNum.integerValue];
    }

    // Forge/NeoForge 警告
    if ([loader isEqualToString:@"Forge"] || [loader isEqualToString:@"NeoForge"]) {
        [message appendFormat:@"\n⚠️ 注意: %@ %@ 加载器需通过下载界面手动安装，否则启动会失败。", loader, loaderVersion];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入整合包"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        self.currentImportingModpack = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startModpackImport:modpackInfo];
    }]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 导入流程

- (void)startModpackImport:(NSDictionary *)modpackInfo {
    // 重置取消状态
    [self.importService resetCancelState];

    // Task 5.1：不再显示自定义进度卡——importModpack 内部注册 DownloadTaskManager
    // 主任务（autoPresentDetail=YES），统一进度页自动弹出并接管全部进度展示；
    // 取消统一经由进度页"取消"按钮 → manager 置 Cancelled → service 轮询感知。
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __block NSError *error = nil;
        __block BOOL success = NO;

        @try {
            success = [self.importService importModpack:modpackInfo
                                               progress:^(double progress, NSString *stageMessage) {
                // 进度细节已由 service 上报到统一进度页（阶段/文件计数/字节），
                // 此回调仅保留日志用途，驱动旧自定义进度卡的主线程刷新已移除。
                NSLog(@"[ModpackImport] progress %.0f%%: %@", progress * 100, stageMessage);
            } error:&error];
        } @catch (NSException *exception) {
            error = [NSError errorWithDomain:@"ModpackImportError" code:9998
                                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"导入异常: %@", exception.reason]}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // 检测是否被取消
            BOOL wasCancelled = [error.domain isEqualToString:@"ModpackImportError"] && error.code == 9999;
            NSString *localizedDesc = error.localizedDescription ?: @"";
            if (!wasCancelled && [localizedDesc containsString:@"取消"]) {
                wasCancelled = YES;
            }

            if (wasCancelled) {
                self.currentImportingModpack = nil;
                [self showAlertWithTitle:@"已取消" message:@"导入已取消"];
                return;
            }

            if (success) {
                self.currentImportingModpack = nil;
                [self showImportSuccess:modpackInfo];
            } else {
                // 阶段5修复（参照 FCL）：错误消息中追加失败文件列表（如有），
                // 让用户清楚知道是哪些 mod 下载失败，而不是只看到一个笼统的错误。
                NSString *message = error.localizedDescription ?: @"未知错误";
                NSArray<NSDictionary *> *failed = self.importService.failedFiles;
                if (failed.count > 0) {
                    NSMutableString *msg = [NSMutableString stringWithString:message];
                    [msg appendFormat:@"\n\n失败文件（共 %lu 个）：", (unsigned long)failed.count];
                    NSUInteger showCount = MIN(failed.count, (NSUInteger)5);
                    for (NSUInteger k = 0; k < showCount; k++) {
                        NSString *n = failed[k][@"fileName"] ?: failed[k][@"name"];
                        [msg appendFormat:@"\n  • %@", n ?: @"(unknown)"];
                    }
                    if (failed.count > showCount) {
                        [msg appendFormat:@"\n  ...等共 %lu 个", (unsigned long)failed.count];
                    }
                    message = [msg copy];
                }
                self.currentImportingModpack = nil;
                [self showAlertWithTitle:@"导入失败" message:message];
            }
        });
    });
}

- (void)showImportSuccess:(NSDictionary *)modpackInfo {
    NSString *loader = modpackInfo[@"loader"];
    NSString *name = modpackInfo[@"name"];
    NSMutableString *msg = [NSMutableString stringWithFormat:@"整合包 '%@' 已成功导入。", name];
    if ([loader isEqualToString:@"Forge"] || [loader isEqualToString:@"NeoForge"]) {
        [msg appendFormat:@"\n\n注意: 此整合包使用 %@ %@ 加载器，请先通过下载界面手动安装该加载器版本，否则启动会失败。", loader, modpackInfo[@"loaderVersion"]];
    }

    // Task 5.2：成功结果中明确列出被跳过的文件（404/server-only 等），
    // 让用户知晓整合包可能不完整（此前仅在控制台日志可见）。
    NSArray<NSDictionary *> *skipped = [self.importService skippedDownloadFiles];
    if (skipped.count > 0) {
        [msg appendFormat:@"\n\n跳过文件（共 %lu 个，源上不存在或仅服务端适用）：", (unsigned long)skipped.count];
        NSUInteger showCount = MIN(skipped.count, (NSUInteger)5);
        for (NSUInteger k = 0; k < showCount; k++) {
            NSString *n = skipped[k][@"fileName"] ?: @"(unknown)";
            [msg appendFormat:@"\n  • %@", n];
        }
        if (skipped.count > showCount) {
            [msg appendFormat:@"\n  ...等共 %lu 个", (unsigned long)skipped.count];
        }
    }
    NSString *finalMsg = [msg copy];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功"
                                                                   message:finalMsg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [self loadImportedModpacks];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"立即启动" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self loadImportedModpacks];
        [self launchModpack:modpackInfo];
    }]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.importedModpacks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackCell" forIndexPath:indexPath];
    // 重置 cell 样式
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    // 重置 cell 样式：移除旧的 blurView 和 shadowView（cell 复用）
    for (UIView *subview in cell.contentView.subviews) {
        if ([subview isKindOfClass:[UIVisualEffectView class]] ||
            (subview.layer.shadowOpacity > 0.0f)) {
            [subview removeFromSuperview];
        }
    }

    NSDictionary *modpack = self.importedModpacks[indexPath.row];
    NSString *name = modpack[@"name"] ?: @"未知";
    NSString *mcVersion = modpack[@"minecraftVersion"] ?: @"未知";
    NSString *loader = modpack[@"loader"] ?: @"未知";

    cell.textLabel.text = name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Minecraft %@ - %@", mcVersion, loader];
    cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = [UIColor clearColor];

    // 阶段6视觉统一：参照 ModernAssetCell / ModVersionTableViewCell / VersionCardCell 的卡片规范
    // （cornerRadius 12 + cornerCurve continuous + shadow offset 2/opacity 0.10/radius 4 + leading/trailing 10）
    // 由于 UIVisualEffectView 的 masksToBounds=YES 会同时裁剪 blur 和 shadow，需要单独的 shadowView
    // 提供阴影（与 blurView 同 frame），blurView 在上层提供毛玻璃效果。
    UIView *shadowView = [[UIView alloc] init];
    shadowView.translatesAutoresizingMaskIntoConstraints = NO;
    shadowView.layer.cornerRadius = 12;
    shadowView.layer.cornerCurve = kCACornerCurveContinuous;
    shadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    shadowView.layer.shadowOffset = CGSizeMake(0, 2);
    shadowView.layer.shadowOpacity = 0.10;
    shadowView.layer.shadowRadius = 4;
    shadowView.layer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08].CGColor;
    [cell.contentView insertSubview:shadowView atIndex:0];

    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.layer.cornerRadius = 12;
    blurView.layer.cornerCurve = kCACornerCurveContinuous;
    blurView.layer.masksToBounds = YES;
    [cell.contentView insertSubview:blurView atIndex:1];
    [NSLayoutConstraint activateConstraints:@[
        [shadowView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [shadowView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:10],
        [shadowView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-10],
        [shadowView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
        [blurView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [blurView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:10],
        [blurView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-10],
        [blurView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]
    ]];
    cell.backgroundView = nil;
    return cell;
}

#pragma mark - UITableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *modpack = self.importedModpacks[indexPath.row];
    [self showModpackOptions:modpack];
}

- (void)showModpackOptions:(NSDictionary *)modpack {
    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:modpack[@"name"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"启动整合包" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self launchModpack:modpack];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteModpack:modpack];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        actionSheet.popoverPresentationController.sourceView = self.view;
        actionSheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:actionSheet animated:YES completion:nil];
}

- (void)launchModpack:(NSDictionary *)modpack {
    NSString *profileName = modpack[@"profileName"];
    if (profileName && PLProfiles.current.profiles[profileName]) {
        PLProfiles.current.selectedProfileName = profileName;
        [self showAlertWithTitle:@"配置文件已选择" message:[NSString stringWithFormat:@"已切换到整合包配置文件: %@", profileName]];
    } else {
        [self showAlertWithTitle:@"错误" message:@"找不到整合包配置文件"];
    }
}

- (void)deleteModpack:(NSDictionary *)modpack {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认删除" message:[NSString stringWithFormat:@"删除整合包 '%@'？此操作无法撤销。", modpack[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self showLoadingHUD:@"正在删除整合包..."];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error = nil;
            BOOL success = [self.importService deleteModpack:modpack error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingHUD];
                if (success) {
                    [self loadImportedModpacks];
                } else {
                    [self showAlertWithTitle:@"删除失败" message:error.localizedDescription];
                }
            });
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark - 辅助方法

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    [self showAlertWithTitle:title message:message completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message completion:(void (^ _Nullable)(void))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (completion) completion();
    }]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 重新应用透明化，确保背景效果切换后视图仍能透出全局背景
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        [[BackgroundManager sharedManager] applyEffectToView:self.view];
        [self.tableView reloadData];
    });
}

@end
