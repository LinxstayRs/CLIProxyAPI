# Zeabur 单机部署

这个分支使用上游发布的 `eceasy/cli-proxy-api:v7.3.15` 成品镜像，并固定多架构 manifest digest，为 Zeabur 增加首次启动配置和持久化支持。程序版本由成品镜像决定，不再由 Zeabur 编译 CPA 源码；Docker 构建只额外编译一个使用 Go 标准库的轻量请求过滤器。集群模式保留但默认不启用。更新程序时必须同时更新 Dockerfile 中的版本标签和 digest，单独同步源码不会改变 CPA 运行版本。

## 环境变量

首次部署必须设置：

- `CPA_API_KEY`：客户端（例如 Operit）调用代理 API 时使用的密钥。
- `CPA_MANAGEMENT_KEY`：登录管理面板和调用管理 API 时使用的密钥。
- `PORT=8080`：Zeabur 对外服务端口，由请求过滤器监听。
- `CPA_INTERNAL_PORT=8317`：CPA 容器内回环端口，一般不需要修改。
- `CPA_BLOCKED_DOMAINS=skynexyl.com`：以逗号分隔的 `Origin` / `Referer` 域名黑名单；同时匹配子域名。
- `CPA_BLOCKED_REQUESTED_WITH=com.skynex.app`：以逗号分隔的 `X-Requested-With` 黑名单。
- `TZ=Asia/Shanghai`：时区，可选。

两条密钥只允许使用英文字母、数字以及 `.`、`_`、`~`、`-`。建议分别生成至少 32 位的随机值，且不要使用仓库示例值。

不要设置 `DEPLOY=cloud`，也不要设置 `HOME_JWT`；前者属于原版云端待机模式，后者用于不需要的集群节点模式。

## 持久化

在 Zeabur 为服务添加 Persistent Volume，并挂载到：

`/data`

这里同时保存：

- `/data/config.yaml`：管理面板中的设置；
- `/data/auths/`：OAuth 登录凭证和账号状态；
- `/data/plugins/`：通过管理面板安装的插件文件。

初始配置会启用插件，并把插件目录固定到 `/data/plugins`；因此插件和账号一样会随持久卷保留。没有挂载持久卷时，重新部署可能丢失配置、登录账号和插件。

## 首次启动

启动脚本只会在 `/data/config.yaml` 不存在或为空时，用环境变量生成初始配置。之后重启或重新部署会保留管理面板中的修改，不会用环境变量覆盖。

因此，服务完成首次启动后再修改 `CPA_API_KEY` 或 `CPA_MANAGEMENT_KEY`，不会自动修改现有配置。请在管理面板内修改；如果确实要重新初始化，需先备份后删除持久卷中的 `config.yaml`。

部署成功后访问：

`https://你的域名/management.html`

使用 `CPA_MANAGEMENT_KEY` 登录。客户端使用 `CPA_API_KEY`，API 根地址通常为：

`https://你的域名/v1`

## 资源说明

部署阶段只拉取固定版本的成品镜像并加入启动脚本，不再下载 Go 依赖或编译程序。保留原有 `/data` 持久卷、环境变量和 8080 服务端口，不要新建空卷替换现有数据。镜像保留上游动态插件支持，但插件仍需按新版本实际验证兼容性。部署后核对版本、账号、插件及一次真实请求；缓存命中率单独观察，更新不保证修复缓存。回退可恢复更新前的 Git 提交并重新部署；Git 回退不等于数据回退，生产数据需在 Zeabur 另行备份。