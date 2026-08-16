# Checklist

## 参考仓库
- [ ] `ThirdParty/ZalithLauncher2` 子模块存在，`.gitmodules` 含正确 URL，父仓库 gitlink 已加入索引

## Phase 1：基础设施
- [ ] `PLMirrorCenter` 中不存在散落的 BMCLAPI/MCIM 根 URL 硬编码（全仓库 grep 仅此一处定义）
- [ ] `URLsForOriginal:resourceType:` 对 piston-meta / libraries.minecraft.net / resources.download.minecraft.net / cdn.modrinth.com / edge.forgecdn.net / meta.fabricmc.net 等均能返回正确候选列表
- [ ] `PLDownloadClient`：首选镜像 500 错误时自动切换下一候选且进度不回退跳变
- [ ] `PLDownloadClient`：SHA1 不匹配时删除残留并退避重试
- [ ] 聚合失败错误包含每个候选 URL 的失败原因

## Phase 2：任务系统
- [ ] 暂停 50% → 杀 App → 重启 → 继续下载从 ~50% 恢复（非从 0）
- [ ] App 重启后任务列表恢复（进行中任务显示为已暂停）
- [ ] 下载历史可查看且上限自动清理
- [ ] 同时发起 5 个下载时仅 3 个真正传输，其余排队

## Phase 3：整合包
- [ ] 导入 100+ Mod 整合包时观察到文件级并发（≥8 同时传输）
- [ ] 源码中不再有 `dispatch_semaphore_wait` 阻塞式下载与 `NSThread sleepForTimeInterval` 重试等待（ModpackImportService 下载路径）
- [ ] 篡改 sha1 的测试文件被拦截并记入失败列表
- [ ] 404 文件跳过且导入继续，完成后有明确警告

## Phase 4：镜像策略
- [ ] 旧 `general.download_source=mcim` 升级后自动映射为资源类 mirror_first
- [ ] 设置页可见 4 个分类镜像策略项
- [ ] Mod 下载走 BMCLAPI 候选可用（镜像优先时）
- [ ] MCIMMirror 类已删除且无残留引用
- [ ] Fabric meta/maven 请求在镜像优先时经 BMCLAPI

## Phase 5：校验与增量
- [ ] 重复下载同版本完好 Mod 不产生网络流量即完成
- [ ] 损坏的已存在文件触发重新下载而非跳过

## Phase 6：UI
- [ ] 下载卡片显示实时速率（MB/s）
- [ ] 整合包进度显示"文件数 + 字节数"双维度
- [ ] zh-Hans/zh-Hant/en 本地化无缺失键（其他语言回退英文）

## 构建验证
- [ ] GitHub Actions 构建（development.yml）通过，产出 ipa/tipa
- [ ] 最低支持 iOS 14.0 未被破坏（未使用 iOS 14+ 独有 API，或已做可用性判断）
