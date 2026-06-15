# 星星守护者 — 特殊儿童陪伴系统

面向 ADHD（注意缺陷多动障碍）与自闭症谱系家庭及学校的"边缘+云"陪伴方案，支持三种模式：

| 模式 | 核心场景 | 硬件 | 代码目录 |
|------|---------|------|---------|
| **家庭版-多动症** | 心率/压力监测 → 报警 → 正念呼吸 → AI 建议 + 星星语音陪伴 | 小米手环 + 毛绒球呼吸灯 + 星星机器人 | `lib/` · `ESP32-S3-LCD-1.47B/` · `xiaozhi-esp32-2.2.4/` · `server/` |
| **家庭版-孤独症** | 家长选训练场景 → AI 生成图片 → 星星展示 → 孩子图片交互 | 星星机器人 | `lib/` · `xingxing/` · `server/` |
| **教师版** | 多名学生手环同时监测 → 心率异常立即提醒老师并标注孩子名字 | 小米手环（老师+学生各戴） | `lib/` · `xiaozhi-esp32-2.2.4/` · `server/` |

### 家庭版-多动症
![系统示意图：家庭版-多动症](docs/images/README-system-overview-family-ADHD.jpg)

### 家庭版-孤独症
![系统示意图：家庭版-孤独症](docs/images/README-system-overview-family-autism.jpg)

### 教师版
![系统示意图：教师版](docs/images/README-system-overview-teacher.jpg)

---

## 目录

- [1. 仓库结构](#1-仓库结构)
- [2. 模式一：家庭版-多动症](#2-模式一家庭版-多动症)
- [3. 模式二：家庭版-孤独症](#3-模式二家庭版-孤独症)
- [4. 模式三：教师版](#4-模式三教师版)
- [5. Flutter App 整体结构](#5-flutter-app-整体结构)
- [6. 云端服务（server/）](#6-云端服务server)
- [7. API 速查](#7-api-速查)
- [8. 部署指引](#8-部署指引)
- [9. 已知限制](#9-已知限制)

---

## 1. 仓库结构

```text
ADHD_Monitor/
├── lib/                        # Flutter App（三种模式共用入口）
│   ├── main.dart               # AppModeShell：启动时选择模式（家长/教师）
│   ├── screens/
│   │   ├── home_screen.dart    # 家庭版-多动症主界面
│   │   ├── autism_family_shell.dart  # 家庭版-孤独症主界面
│   │   ├── breathing_ball_page.dart  # 正念呼吸球页面
│   │   ├── esp_provision_page.dart   # BLE 配网页面
│   │   ├── footprint_page.dart       # 今日足迹 / AI 趋势
│   │   └── weekly_report_page.dart   # AI 周报
│   ├── teacher/
│   │   ├── teacher_shell.dart        # 教师版主界面
│   │   ├── teacher_ble_service.dart  # 多手环 BLE 管理
│   │   ├── teacher_models.dart       # 学生/报警数据模型
│   │   └── teacher_local_store.dart  # 本地持久化
│   └── services/               # MiBand / Cloud / ESP 配网 / 压力计算等
│
├── ESP32-S3-LCD-1.47B/         # 毛绒球呼吸灯固件（家庭版-多动症）
│
├── xiaozhi-esp32-2.2.4/        # 星星机器人固件（家庭版-多动症 语音陪伴 / 教师版通知）
│   └── main/
│       ├── adhd_remote_cmd.cc  # 长轮询接收 xiaozhi_invoke_chat 命令
│       ├── adhd_prov_ble.cc    # BLE 配网（与毛绒球同协议）
│       └── application.cc      # Bypass OTA，强制 WebSocket 语音协议
│
├── xingxing/                   # 星星机器人固件（家庭版-孤独症 图片交互）
│   └── main/
│       ├── action_cards.cc     # 图片卡片展示 + 摇晃/拍打交互
│       └── adhd_remote_cmd.cc  # 接收训练场景命令 + 下载图片
│
└── server/                     # 腾讯云 Flask 服务
    ├── app.py                  # 主程序：路由 / Kimi / 周报 / 长轮询 / 图片生成
    └── xiaozhi_bridge.py       # /xiaozhi/ws WebSocket 语音桥接
```

---

## 2. 模式一：家庭版-多动症

**场景**：孩子佩戴小米手环，家长手持手机。心率/压力异常时 App 报警，引导孩子正念呼吸（毛绒球呼吸灯联动），家长记录后星星机器人主动开口陪伴孩子。

```mermaid
flowchart TD
    Band["小米手环\nBLE HR + Stress 通知"]

    subgraph App["Flutter App — home_screen.dart"]
        A1["实时心率/压力展示"]
        A2{{"触发报警?\nbpm≥120 或 stress≥60"}}
        A3["显示报警\n震动 + TTS"]
        A4["家长确认\n选择干预方式"]
        A5a["引导正念呼吸\nBreathingBallPage"]
        A5b["写行为记录\n提交 /submit_log"]
        A6["显示 Kimi 建议"]
    end

    subgraph Cloud["Flask 云端 — server/app.py"]
        C1["POST /webhook\n心率落盘"]
        C2["POST /submit_log\nKimi 建议 + 入队唤醒"]
        C3["POST /device/cmd\n推呼吸命令"]
        C4[["xiaozhi_invoke_chat\n命令队列"]]
    end

    subgraph Lamp["毛绒球 — ESP32-S3-LCD-1.47B"]
        L1["长轮询 /device/cmd"]
        L2["呼吸灯 + LCD 全屏琥珀色\nRGB_Start_Breathing"]
    end

    subgraph Xz["星星机器人 — xiaozhi-esp32-2.2.4"]
        X1["长轮询 /device/MAC/cmd"]
        X2["WakeWordInvoke\n连接 /xiaozhi/ws"]
        X3["Opus 语音对话\n百度ASR → Kimi → edge-tts"]
    end

    Band -->|"BLE notify"| A1
    A1 --> A2
    A2 -->|"是"| A3
    A3 --> A4
    A4 --> A5a
    A4 --> A5b
    A5a -->|"breathing_start"| C3
    C3 --> L1
    L1 --> L2
    A5b --> C2
    C2 -->|"Kimi 建议"| A6
    C2 -->|"入队"| C4
    C4 -->|"notify 唤醒"| X1
    X1 --> X2
    X2 --> X3
    A1 -->|"批量上传"| C1
```

### 2.1 设备首次配网流程

```mermaid
sequenceDiagram
    participant App as Flutter App
    participant Board as ESP32 设备
    participant Cloud as Flask 云端

    App->>Board: BLE 扫描 ADHD_xxxx / XIAOZHI_xxxx
    App->>Board: sec0 握手 + WiFi SSID/密码
    Board->>Board: 写 NVS → 连 WiFi → 关 BLE
    Board->>Cloud: POST /device/esp32/announce
    App->>Cloud: POST /device/esp32/bind 绑定到孩子
```

毛绒球广播名：ADHD_<MAC末4字节>；星星机器人广播名：XIAOZHI_<MAC8>。配网后 BLE 自动关闭，之后全部走云端中转。

### 2.2 心率报警去抖

- **bpm 通道**：每 3 s 拉 GET /webhook，lert=true 触发。
- **stress 通道**：手环私有特征，阈值默认 60（App 顶栏可调 30-90）。
- **抑制窗口**：报警确认后 45 s 内或服务器返回一次 lert=false 即解除，避免重复弹出。

### 2.3 呼吸 Watchdog

reathing_start 命令携带 	tl_ms（默认 10 分钟）。若手机离线导致 reathing_stop 永远到不了，毛绒球也会在超时后自动熄灯，防止一直亮着。

---

## 3. 模式二：家庭版-孤独症

**场景**：家长从 App 选择训练场景，云端生成选项图片并下发给 xingxing 设备，孩子通过**摇晃**切换选项、**拍打**确认，结果回传家长手机。

```mermaid
flowchart TD
    subgraph App["Flutter App — autism_family_shell.dart"]
        B1["选择训练模式\n情绪表达 / 需求表达 / 社交回应\n偏好选择 / 寻求帮助 / 日程计划"]
        B2["配置选项内容\n（可自定义文字/图片）"]
        B3["POST /training/start\n下发场景到设备"]
        B4["收到孩子选择结果\n展示 + 记录"]
    end

    subgraph Cloud["Flask 云端 — server/app.py"]
        C1["接收训练场景\n调 Kimi 生成图片描述"]
        C2["生成/保存 PNG 图片\nassets/action/"]
        C3["入队 choice_preview 命令\n携带图片 URL"]
    end

    subgraph Xingxing["星星机器人 — xingxing/"]
        X1["长轮询 /device/MAC/cmd\nadhd_remote_cmd.cc"]
        X2["下载图片\nHTTP GET 图片 URL"]
        X3["LCD 全屏显示图片\naction_cards.cc"]
        X4["孩子摇晃 → 切换下一张\n孩子拍打 → 确认选择"]
        X5["POST 选择结果\n回云端"]
    end

    B1 --> B2 --> B3
    B3 --> C1 --> C2 --> C3
    C3 -->|"notify 唤醒"| X1
    X1 --> X2 --> X3 --> X4 --> X5
    X5 -->|"回调通知"| B4
```

### 3.1 训练场景列表

| 场景 | 孩子操作 | 机器人行为 |
|------|---------|-----------|
| 情绪表达 | 摇晃切换开心/难过/生气/害怕，拍打确认 | 复述选择并表扬 |
| 需求表达 | 选择喝水/吃东西/上厕所/休息 | 告知家长，家长手机震动 |
| 社交回应 | 选择打招呼回应 | 继续追问，训练对话 |
| 偏好选择 | 从家长预设选项中选择 | 确认并鼓励执行 |
| 寻求帮助 | 选择"需要/不需要帮忙" | 告知家长 |

### 3.2 图片交互机制（xingxing 固件）

```mermaid
flowchart LR
    Cmd["收到 choice_preview 命令\n含图片URL列表"] --> DL["后台下载图片\nHTTP → LVGL JPEG"]
    DL --> Show["LCD 全屏显示第一张\n播放 TTS 语音引导"]
    Show --> Shake["孩子摇晃设备\nMPU 检测 → Next()"]
    Shake --> Show
    Show --> Tap["孩子拍打/按键\nConfirmSelection()"]
    Tap --> Post["POST 选择结果\n→ 云端 → App 通知家长"]
    Post --> Praise["播放表扬语音"]
```

---

## 4. 模式三：教师版

**场景**：老师和最多 3 名学生各自佩戴小米手环，App 直接通过 BLE 同时连接全部手环，任一学生心率异常时 App 立即报警并标注学生姓名，老师手环同步震动提醒。

```mermaid
flowchart TD
    subgraph Bands["小米手环 × (1+N)"]
        TB["老师手环\nBLE"]
        SB1["学生1手环\nBLE"]
        SB2["学生2手环\nBLE"]
        SB3["学生3手环\nBLE"]
    end

    subgraph App["Flutter App — teacher/teacher_shell.dart"]
        T1["TeacherBleService\n同时连接全部手环"]
        T2["实时心率显示\n每个学生独立卡片"]
        T3{{"心率超阈值?\n持续偏高 / 骤升 / 持续偏低"}}
        T4["App 弹窗报警\n标注学生姓名 + 事件类型"]
        T5["老师手环震动\n+ 写入 2A46 短句"]
        T6["记录告警事件\n上传云端"]
    end

    subgraph Cloud["Flask 云端"]
        C1["POST /webhook\n告警事件落盘"]
    end

    TB -->|"BLE HR notify"| T1
    SB1 -->|"BLE HR notify"| T1
    SB2 -->|"BLE HR notify"| T1
    SB3 -->|"BLE HR notify"| T1
    T1 --> T2
    T2 --> T3
    T3 -->|"是"| T4
    T4 --> T5
    T4 --> T6
    T6 --> C1
```

### 4.1 报警规则

| 规则 | 触发条件 |
|------|---------|
| 心率持续偏高 | 连续 N 次采样 ≥ 学生设定阈值（默认 120） |
| 心率持续偏低 | 连续 N 次采样 ≤ 低阈值（默认 70） |
| 心率短时骤升 | 5 分钟内较近期基线上升 ≥ 30% |

- 每个学生阈值可单独配置，并按年龄段给出参考正常范围。
- 同一学生报警后 90 秒内不重复弹出（冷却期）。
- 老师手环通过写 BLE GATT 特征  x2A46 发送包含学生姓名的振动短句。

---

## 5. Flutter App 整体结构

```mermaid
flowchart TB
    Main["main.dart\nAppModeShell"]

    Main -->|"未选择模式"| Choose["_ModeChoicePage\n选择家长/教师"]
    Main -->|"AppMode.parent"| Family["FamilyShell"]
    Main -->|"AppMode.teacher"| Teacher["TeacherShell\nteacher/teacher_shell.dart"]

    Family -->|"孩子类别=ADHD"| ADHD["AdhdMonitorApp\nscreens/home_screen.dart"]
    Family -->|"孩子类别=autism"| Autism["AutismFamilyShell\nscreens/autism_family_shell.dart"]

    ADHD --> HR["心率/压力实时监测"]
    ADHD --> Breath["BreathingBallPage\n正念呼吸"]
    ADHD --> Foot["FootprintPage\n今日足迹"]
    ADHD --> Weekly["WeeklyReportPage\nAI 周报"]
    ADHD --> Prov["EspProvisionPage\nBLE 配网毛绒球/星星"]

    Autism --> Scene["训练场景选择"]
    Autism --> Schedule["日程计划表"]
    Autism --> AutismProv["EspProvisionPage\nBLE 配网 xingxing"]

    subgraph Services["共用服务层 lib/services/"]
        Mi["miband_service.dart\nMiBand6Auth BLE"]
        Cloud["cloud_service.dart\nHTTP 封装"]
        Prov2["esp_provision_service.dart\nBLE 配网"]
        Stress["stress_calculator.dart\nHR→压力估算"]
        FG["foreground_task_service.dart\nAndroid 守护进程"]
    end
```

### 模式切换说明

启动时若无缓存模式记录则弹出选择页；家长模式下进入孩子档案页面后可根据孩子**疾病类别**自动路由到多动症或孤独症界面。切换模式需从顶栏菜单退出。

---

## 6. 云端服务（server/）

### 6.1 整体结构

```mermaid
flowchart LR
    PM2["PM2\necosystem.config.js"] --> Flask["Flask\napp.py\n0.0.0.0:11760"]
    Flask --> DB[("SQLite\nadhd_data.db")]
    Flask --> Kimi["Kimi API\nkimi-k2.5"]
    Flask --> Bridge["xiaozhi_bridge.py\nWS /xiaozhi/ws"]
    Flask --> Sched["周报守护线程\n每周日 21:00"]
    Bridge --> BaiduASR["百度短语音 ASR"]
    Bridge --> EdgeTTS["edge-tts"]
```

### 6.2 ESP32 长轮询命令通道

App 推命令 → 云端用 	hreading.Condition 立即唤醒正在 hold 的设备连接 → 设备收到后执行，延迟 < 100 ms。

```mermaid
sequenceDiagram
    participant Device as ESP32 设备
    participant Flask
    participant App as Flutter App

    Device->>Flask: GET /device/<id>/cmd?wait=25（阻塞）
    App->>Flask: POST /device/<id>/cmd {action:...}
    Flask->>Flask: notify_all() 唤醒
    Flask-->>Device: 200 {action, ...}
    Device->>Device: 执行命令
    Device->>Flask: 下一轮 GET（立即）
```

### 6.3 星星机器人语音通道（/xiaozhi/ws）

家长提交行为记录后，星星机器人被自动唤醒主动开口陪伴孩子：

```mermaid
sequenceDiagram
    participant Parent as 家长
    participant App as Flutter App
    participant Flask
    participant Xz as 星星机器人

    Parent->>App: 填写行为记录
    App->>Flask: POST /submit_log
    Flask->>Flask: Kimi 生成建议（50字）
    Flask->>Flask: 对孩子名下 xiaozhi 设备入队 xiaozhi_invoke_chat
    Flask-->>App: 返回建议文字
    Xz->>Flask: 长轮询 GET /device/MAC/cmd（已阻塞）
    Flask-->>Xz: {action: xiaozhi_invoke_chat}
    Xz->>Flask: WS 连接 /xiaozhi/ws
    Note over Xz,Flask: 上行 Opus → 百度ASR → Kimi → edge-tts → 下行 Opus
```

### 6.4 孤独症训练图片服务

```mermaid
flowchart LR
    App["App POST /training/start\n{scene_id, options, tts_intro}"] --> Gen["Kimi 生成图片描述\n或使用预置资源"]
    Gen --> Save["保存 PNG 到\nserver/action/"]
    Save --> Queue["入队 choice_preview\n携带图片 URL 列表"]
    Queue --> Xingxing["xingxing 下载并展示"]
    Xingxing --> Result["POST /training/choice\n选择结果回传"]
    Result --> Notify["App WebSocket/轮询\n通知家长"]
```

---

## 7. API 速查

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | /auth/register / /auth/login | 注册 / 登录，返回 Bearer token |
| GET/POST | /webhook | 心率上传 / 查询最新状态 |
| POST | /submit_log | 写行为记录 + Kimi 建议 + 星星唤醒 |
| GET | /footprint/today | 今日记录 + 干预前后趋势 |
| GET | /weekly_report/latest | 最新 AI 周报 |
| POST | /training/start | 下发孤独症训练场景（图片+语音） |
| POST | /device/esp32/announce | 设备上电自报 |
| GET/POST | /device/<id>/cmd | 长轮询拉取 / 推送命令 |
| WS | /xiaozhi/ws | 星星机器人语音上下行（Opus） |
| GET | /my/children | 查看孩子列表 |
| POST | /device/esp32/bind | 绑定 ESP32 到孩子（kind 区分毛绒球/星星/xingxing） |

---

## 8. 部署指引

### 8.1 云端服务（server/）

`ash
cd server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example ~/.config/adhd-monitor.env
# 编辑填入 MOONSHOT_API_KEY / BAIDU_SPEECH_API_KEY 等
pm2 startOrRestart ecosystem.config.js
```

主要环境变量：MOONSHOT_API_KEY（必填）、BAIDU_SPEECH_API_KEY / BAIDU_SPEECH_SECRET_KEY（星星语音必填）、XIAOZHI_WEBSOCKET_TOKEN（可选，WebSocket 鉴权）。

### 8.2 毛绒球固件（ESP32-S3-LCD-1.47B/）

```powershell
cd ESP32-S3-LCD-1.47B
.\idf.ps1 set-target esp32s3
.\idf.ps1 menuconfig   # 填写 ADHD Cloud host/port
.\idf.ps1 build
.\idf.ps1 -p COM4 flash monitor
```

### 8.3 星星机器人固件

**家庭版-多动症**（xiaozhi-esp32-2.2.4/）：

```powershell
cd xiaozhi-esp32-2.2.4
# menuconfig → ADHD Monitor integration:
#   启用 Long-poll /device/<mac>/cmd
#   填写 ADHD_MONITOR_CMD_HOST / PORT
#   填写 ADHD_MONITOR_WS_URL (ws://<host>:11760/xiaozhi/ws)
#   WiFi Config Method → ADHD Monitor BLE (network_provisioning, sec0)
.\build.bat
.\flash.bat
```

**家庭版-孤独症**（xingxing/）：

```powershell
cd xingxing
# menuconfig → 填写 ADHD Monitor host/port
.\build.bat
.\flash.bat
```

### 8.4 Flutter App（lib/）

`ash
flutter pub get
flutter run    # 需真机（BLE）
```

---

## 9. 已知限制

- 目前仅支持**小米手环 6**；教师版最多同时连接 3 名学生手环。
- 目前仅支持 **Android**；iOS 需要额外处理蓝牙后台权限。
- Android 不允许读取当前 WiFi 密码，BLE 配网时**必须手动输入**。
- 孤独症模式图片由 Kimi 文字描述后本地生成，复杂场景图质量依赖 prompt。
- AI 周报守护线程目前固定 child_id=1；多孩子家庭需手动 POST /weekly_report/generate。
- 家长吐槽内容无法自动推送小红书（小红书未开放创作接口）。
