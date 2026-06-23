# 《温柔的信号》— 科技温情陪伴短片 · 故事分镜表

> 一部关于科技如何成为情感桥梁的微电影。当孩子在书桌前与难题搏斗、被焦虑悄悄淹没时，
> 一条无声的信号穿过墙壁、越过云端，化作一束暖光、一段乐曲、一句温柔的问候。
> 科技在这里不是冰冷的机器，而是父母之爱的延伸。

> **相关文档**：本片资产与道具提示词清单见 `docs/AIGC_ASSET_PROMPTS.md`；通用元提示词见 `docs/META_PROMPTS_AI_VIDEO_PRODUCTION.md`（**第一节**生成分镜稿，**第二节**从分镜生成资产清单，**第三节**图生视频通用模板）。**逐镜生图提示词、即梦流程、制作与旁白备注**均在本文件第三至六章；**在 Cursor 里辅助写字幕表、镜头核对表、脚本等**见**第七章**。

---

## 一、项目总览（Creative Brief）

| 项目 | 设定 |
|------|------|
| 片名 | 《温柔的信号 / The Gentle Signal》 |
| 时长 | 成片实际 **约 81.5 秒**（**片头字幕卡 3s + 0.5s 黑场 + M01–M10 约 71s + M11 约 7.4s**）。①–⑩ 仍可单独裁剪至 75–90s 区间。**⑪** 为**四张真机截图合成图（左手机右文字布局）+ 功能文案**的落版段，可整段删去作纯情感版 |
| 风格基调 | **真人实拍写实风格**（photorealistic / live-action，非动画、非插画、非 3D 渲染）、温暖治愈、细腻自然、略带科技未来感 |
| 时间设定 | **故事发生在同一个晚上（约 20:00）**，孩子在书房写作业、父母在客厅——**全片为夜晚室内场景**：窗外漆黑、无日光，唯一光源为室内灯具（书房暖黄台灯 / 客厅落地灯·壁灯）与屏幕冷光 |
| 主色调 | 焦虑段落：冷青灰、低饱和；治愈段落：琥珀暖金、柔光弥散 |
| 画幅 | 成片 **16:9（1280×720，60fps，H.264）**；原脚本规划 2.39:1，最终制作以 FFmpeg 非线性输出为准（可另行加黑边适配 2.39:1 / 9:16 竖版） |
| 镜头语言 | 浅景深、自然光为主、缓慢推拉、特写情绪 |
| 整体节奏 | 前段压抑紧凑 → 中段信号流转 → 后段舒缓呼吸 |
| 音乐主线 | 432Hz 钢琴 + 弦乐铺底，从"留白—脉冲—温暖回升"三段式 |
| 旁白声线 | **全片画外旁白统一温柔女声**（录制规范见第四章「旁白声线统一」） |
| 情绪曲线 | 焦虑(↑) → 报警(峰值) → 介入(转折) → 平复(↓) → 温暖(回归平稳) |

### 角色设定
- **孩子（朗朗，9–10岁）**：中国男孩，活泼好动、精力旺盛，**左手腕**戴智能手环（**全程黑屏、不发光、静默守护**），专注力易分散、遇难题易急躁焦虑。
- **爸爸 / 妈妈**：坐在客厅沙发上，手机端守护者，冷静而充满爱意。
- **毛绒玩具（Glow）**：桌面陪伴用的**毛绒玩具**，内置灯光与音响，可发光、播放音乐的治愈型陪伴玩具。
- **星星机器人（Star）**：桌面交互机器人，星形面屏，特教老师般温柔的声线。

---

## 二、故事分镜表（Shot List / Storyboard）

### 片头字幕卡（3s · FFmpeg 生成 · 不列入镜头编号）

| 字段 | 内容 |
|------|------|
| 时长 | **3 秒**（末尾淡出 0.5s，后接 0.5s 黑场停顿） |
| 内容 | 第一行：「《温柔的信号》」· 第二行：「— 科技温情陪伴短片」 |
| 样式 | 白字居中，黑底；字体 uming.ttc（宋体），行间距适中，背景纯黑 |
| 实现 | Pillow 生成 PNG 后 FFmpeg 转为 60fps 视频（`TITLE.mp4`），末尾烘焙淡出 |

### 镜头 01 — 开场 · 书桌前的专注
| 字段 | 内容 |
|------|------|
| 时长 | 6 秒 |
| 景别 | 中近景 |
| 运镜 | 缓慢推近（Slow Dolly-in），从门口推向书桌 |
| 镜头内容 | 夜晚书房，台灯下孩子低头写数学题，铅笔沙沙作响；书桌一角静静坐着一只可爱的**毛绒玩具**（此刻未亮、安静陪伴） |
| 画面描述 | 暖黄台灯是画面唯一光源，背景虚化成温柔光斑；孩子**左手腕**上戴着智能手环，**屏幕全黑、不发光、完全静默**；书桌前方/一侧摆着一只圆润柔软的毛绒玩具，作为"日常陪伴"埋下伏笔（后续镜头07 它将亮起暖光） |
| 旁白/字幕 | （字幕）"晚上八点，他还在和最后一道题较劲。" |
| 音效 | 铅笔书写声、轻微翻页声、室内静谧的环境音 |
| 音乐 | 单音钢琴留白，几乎静默 |

### 镜头 02 — 难题来袭 · 焦虑萌芽
| 字段 | 内容 |
|------|------|
| 时长 | 6 秒 |
| 景别 | 特写（手部 + 草稿纸） |
| 运镜 | 手持微晃（轻微 handheld），制造不安感 |
| 镜头内容 | 孩子反复涂改、橡皮擦出碎屑，铅笔停顿、指节收紧（写字的**左手腕**带入画面，手环**黑屏、不发光**） |
| 画面描述 | 色温转冷，光线略压暗；草稿纸上画满划掉的算式；若**左手腕**入镜，手环始终**全黑、不发光、静默** |
| 旁白/字幕 | （字幕）"可这一次，怎么都算不对。" |
| 音效 | 橡皮摩擦声、急促的呼吸声渐起、心跳声若隐若现 |
| 音乐 | 低频弦乐缓慢渗入，制造压迫感 |

### 镜头 03 — 心率飙升 · 静默后台示警（空中悬浮可视化）
| 字段 | 内容 |
|------|------|
| 时长 | 8 秒 |
| 景别 | 微距特写（手环）→ 拉开至空中悬浮可视化 |
| 运镜 | 固定起幅于安静的手环屏幕，缓缓后拉并上摇，揭示手腕上方悬浮的心率可视化 |
| 镜头内容 | **左手腕上的手环屏幕全程平静、无任何数字与警示**；镜头上移，**左手腕**上方空中悬浮浮现一段心率波形与跳动数字：98 → 107 → **115 ❤**，超阈值瞬间波形由青转红 |
| 画面描述 | 关键设定：示警完全**静默在后台处理**，手环显示屏不显示任何提示、不震动。心率的攀升与越界，仅以**半透明空中悬浮全息**的形式呈现给观众（孩子本人看不见）——悬浮波形、跳动数值、一条横亘的红色"阈值线"，数值冲破红线的瞬间，悬浮光晕由冷青闪为警示红 |
| 旁白/字幕 | （字幕）"心率 115，悄悄越过了平静线——而他，毫不知情。" |
| 音效 | 心跳声推至最高、悬浮可视化越界时一记极轻的后台"脉冲"音（仅为观众叙事，孩子端完全无声） |
| 音乐 | 弦乐紧张达到小高潮，戛然留白 |

### 镜头 04 — 信号触发 · 父母端关怀提醒
| 字段 | 内容 |
|------|------|
| 时长 | 10 秒 |
| 景别 | 微距特写（手环）→ 特写（父母手机 + 全息气泡） |
| 运镜 | **同镜两段式**：前半特写起幅于孩子**左手腕的手环**，一道细光线自手环升起向上；**镜头跟随光线转入客厅父母手机画面**，后半固定俯拍，手机在妈妈手中轻微震动，细光线接入屏幕后上方浮起全息关怀气泡 |
| 镜头内容 | 心率攀升至 **115** 的瞬间，**一道纤细的数据光线**从孩子**左手腕的手环**位置升起腾空（**手环本体黑屏、不发光**）；**同镜内**光线汇入客厅沙发上妈妈手中的手机，手机亮屏并**震动**；屏幕上方空气中升起**半透明全息关怀气泡框**，框内提示"心率偏高，建议陪伴"（气泡由一缕光丝与手机相连，为面向观众的概念可视化） |
| 画面描述 | **前段（书房）**：暗调夜晚书房，一道**纤细锐利、笔直简洁、充满科技感**的发光数据线从孩子**左手腕**的黑屏手环升起，克制冷静、不华丽（无丝带、无繁复粒子拖尾）。**后段（客厅）**：**同镜转入**夜晚客厅（窗外漆黑、暖色落地灯/壁灯偏暗），父母并肩坐在沙发上，同一道细光线自屏幕边缘接入、点亮手机；妈妈手机震动滑了一下，**手机上方悬浮起一个发着温暖琥珀金光的全息气泡框**（区别于镜头 03 的警示红，标记由报警转向关怀的回暖），气泡光与屏光映亮她的脸，爸爸从旁凑过来一起看 |
| 旁白/字幕 | （旁白·温柔女声）"有些求助，孩子说不出口；好在，有人一直在听。"<br>（全息气泡文字）"⚠ 关怀提醒：朗朗心率 115 bpm，建议给予陪伴。" |
| 音效 | 低沉"嗡"的传输声、数据流粒子音、手机震动声 "嗡嗡"、轻提示音 |
| 音乐 | 单颗钢琴音符如脉冲标记"信号"动机 → 脉冲动机延续，温度开始回升 |

### 镜头 05 — 父母反馈 · 腾讯云生成关怀方案
| 字段 | 内容 |
|------|------|
| 时长 | 14 秒 |
| 景别 | 中景（双人）+ 插入手机屏幕特写 → 概念全景（数字空间可视化） |
| 运镜 | **同镜两段式**：前半轻微环绕（slight arc）聚焦父母神情，插切手机屏幕特写带键盘输入；发送后一道纤细丝滑的数据光线自手机升起，**镜头跟随光线上升并转入抽象数字空间**；后半缓慢环绕推进（orbit-in）至中心光核，指令光线分流射出 |
| 镜头内容 | 父母仍坐在客厅沙发上，妈妈在 App 的**文字输入框**里一字一句敲下"他正在写数学作业"，按下发送；爸爸在旁关切地看。发送瞬间，一道与镜头 04 同款的**纤细丝滑曲线光线**自手机升起腾空；**同镜内**光线汇入 **腾讯云** 中央光核，AI 分析"场景=写数学作业 + 焦虑"，经 **腾讯云 IoT / MQTT** 下发指令，分两束光线分别指向"毛绒玩具""星星机器人" |
| 画面描述 | **前段（客厅实拍）**：沙发上的过肩插入特写，手机 App 场景反馈页有**文本输入框**，软键盘弹起，妈妈的拇指逐字输入"他正在写数学作业"，光标闪烁；发送后屏幕提示"已上报云端，正在生成关怀方案"，一道**纤细丝滑、划出柔和曲线**的数据光线自手机升起。**后段（云端概念）**：镜头随光线转入抽象数据宇宙，场景数据汇入中央光球（可隐约呈现**腾讯云 Logo / "Tencent Cloud" 字样**于光核之上），金色数据光点汇入，MQTT 指令分两束光线射向"毛绒玩具""星星机器人"图标 |
| 旁白/字幕 | （字幕）"不冲进去打断，而是悄悄告诉这个家——他在写作业。"<br>（旁白·温柔女声）"腾讯云读懂了此刻：不是责备，而是陪伴。" |
| 音效 | 轻点按 UI 音效、温柔确认"叮"、数据汇聚的清脆电子音、指令分发"咻咻"声 |
| 音乐 | 弦乐渐转暖并加入温柔和声 → 432Hz 主题动机首次完整浮现（前导） |

### 镜头 06 — 星星机器人 · 温柔开口
| 字段 | 内容 |
|------|------|
| 时长 | 8 秒 |
| 景别 | 中近景（机器人 + 孩子侧脸） |
| 运镜 | 起幅于一道自画面外飘入的细光线接入机器人，缓慢推近机器人星形面屏，再切孩子反应 |
| 镜头内容 | **承接镜头 05 下发的指令**：一道**纤细丝滑、划出柔和曲线**的数据光线自画面外飘入、汇入桌面星星机器人，机器人随之被"唤醒"——面屏率先亮起微笑表情，主动温柔开口，先安抚男孩，再提议跟着毛绒玩具一起深呼吸 |
| 画面描述 | 与镜头 05 同款的**纤细丝滑曲线光线**自画面外接入机器人本体（仅承接指令的概念可视化，**不出现腾讯云字样/Logo**），光线没入机身后星形面屏亮起柔光眼神，成为画面里第一缕暖意；孩子抬头，眼神从紧绷转为好奇，焦虑略微松动（**左手腕**手环始终**黑屏、不发光**） |
| 旁白/字幕 | （机器人台词·特教老师般温柔女声）"小主人，写作业累了吧？别急——我们先和毛绒玩具一起，深呼吸三次吧。" |
| 音效 | 机器人提示音、面屏切换轻"叮"声 |
| 音乐 | 432Hz 钢琴主旋律正式进入（由前导转正式），加入轻柔铃声点缀 |

### 镜头 07 — 毛绒玩具点亮 · 一起呼吸
| 字段 | 内容 |
|------|------|
| 时长 | 10 秒 |
| 景别 | 特写（毛绒玩具）→ 拉开中景（孩子 + 毛绒玩具同框） |
| 运镜 | 固定起幅随光亮缓缓后拉（pull-back reveal），转极缓呼吸式推拉（breathing zoom）与呼吸节奏同步 |
| 镜头内容 | 应机器人之邀，桌上毛绒玩具瞬间亮起治愈琥珀色暖光，光晕在桌面晕染开并随呼吸节奏一胀一缩；男孩跟着光的节奏深呼吸、肩膀放松（**左手腕**手环始终**黑屏、不发光**） |
| 画面描述 | 全片色温转折在此完成——画面由冷转暖，孩子的脸被柔光照亮、焦虑表情松动；光的呼吸与孩子的呼吸同频，画面柔焦、暖意盎然，唯一光源是毛绒玩具与暖光，孩子**左手腕**的手环**全黑、不发光、静默** |
| 旁白/字幕 | （字幕）"一束光，先到了。吸气……呼气……和光一起，慢下来。" |
| 音效 | 柔和"亮起"音、432Hz 乐曲淡入、缓慢的吸气呼气声、光晕脉动的低频"呼…呼…" |
| 音乐 | 432Hz 旋律舒展，弦乐铺底如拥抱，温暖弥散 |

### 镜头 08 — 对话解困 · 一起面对难题
| 字段 | 内容 |
|------|------|
| 时长 | 6 秒 |
| 景别 | 中近景（机器人 + 孩子，正反打） |
| 运镜 | 固定/轻微对切，在机器人面屏与孩子神情间来回 |
| 镜头内容 | 平静下来的男孩转向星星机器人，机器人温柔询问他卡在哪里、引导他说出困难，两人一问一答、一起拆解这道题（**左手腕**手环始终**黑屏、不发光**） |
| 画面描述 | 暖光环绕，男孩指着作业本边说边皱眉、随后渐渐舒展，星形面屏配合点头/眨眼的微表情回应；写字的**左手腕**入镜时，手环**全黑、不发光、静默** |
| 旁白/字幕 | （机器人·特教老师般温柔女声）"现在感觉好一点了吗？刚才那道题，是卡在哪一步了呀？"<br>（孩子·小声）"这道应用题……我不知道该先算哪一个。"<br>（机器人）"别急，我们一起看看？" |
| 音效 | 机器人轻柔提示音、孩子翻动作业本与铅笔轻点声 |
| 音乐 | 432Hz 旋律温暖延展，轻柔铃声点缀 |

### 镜头 09 — 茅塞顿开 · 继续作业
| 字段 | 内容 |
|------|------|
| 时长 | 6 秒 |
| 景别 | 中近景 |
| 运镜 | 固定，轻微推近至笔尖落纸 |
| 镜头内容 | 在机器人引导下男孩忽然想通解法，开心在先前划掉的算式旁流畅写下答案（**左手腕**手环始终**黑屏、不发光**） |
| 画面描述 | 暖光环绕，孩子眼睛一亮、嘴角上扬，铅笔重新流畅书写；写字的**左手腕**入镜时，手环**全黑、不发光、静默** |
| 旁白/字幕 | （孩子·惊喜）"哦——我明白了！！"<br>（机器人·轻声·特教老师般温柔女声）"你看，你自己就能解开它。"（字幕）"难题还在，但他不再孤单。" |
| 音效 | 铅笔顺畅书写声、孩子轻快的笑 |
| 音乐 | 432Hz 主题进入温暖高潮，明亮而安定 |

### 镜头 10 — 父母端 · 心率归于平静 · 收尾
| 字段 | 内容 |
|------|------|
| 时长 | 8 秒 |
| 景别 | 特写（手机）→ 拉远全景（一墙之隔的两个房间） |
| 运镜 | 手机特写后大幅后拉（dolly-out），定格温暖全景 |
| 镜头内容 | 客厅沙发上的父母手机 App 显示心率曲线由红回落至绿色平静区间；镜头拉远，呈现"看不见却紧紧相连"的一家 |
| 画面描述 | 曲线平复，App 显示"朗朗已恢复平静 ❤"；剖面全景里，孩子在书房继续写作业，父母并肩坐在客厅沙发上，两个房间都笼罩在同一片暖光中 |
| 旁白/字幕 | （旁白·温柔女声）"最好的科技，是让爱，准时抵达。"（落版 Logo + Slogan） |
| 音效 | 手机轻"叮"提示、最终一声温柔余音 |
| 音乐 | 432Hz 主题收束，渐弱至温暖留白 |

### 镜头 11 — 功能说明 · 四格真机截图合成（约 7.4s 落版 · 16:9）

> **成片实际采用「左手机右文字」双层 split 合成图**（非纯截图铺屏）。四张合成图由 Python/Pillow 生成，背景为 `M10尾帧.png` 高斯模糊底，左侧展示手机截图，右侧叠加功能文案与 tag，整体统一在 1280×720 画布。

| 字段 | 内容 |
|------|------|
| 时长 | **约 7.4 秒**（小红书段 3.7s + 周报段 3.7s；每段内两张截图各 2s 通过叠化 0.3s 衔接） |
| 画幅 | **1280×720（16:9）**，60fps，H.264 |
| 景别 | **左手机右文字 split 布局**：左半（0–640px）手机截图居中悬浮（高 670px，带圆角+投影），右半（640–1280px）功能文案居中排版 |
| 运镜 | **静帧 + 叠化**：每段两张图各 2s，段内用 `xfade=fade` 叠化 0.3s 衔接（实际每段 3.7s）；两大段（小红书段→周报段）之间硬切 |
| 镜头内容 | 用 **4 张合成图** 呈现两大功能：**一键发布小红书**（`小红书_1` → `小红书_2`）、**周报与 AI 行为分析**（`周报_1` → `周报_2`）。每张合成图左侧为对应真机截图，右侧为功能说明文字 + 「更多功能已上线」琥珀金胶囊 tag |
| 画面描述 | **背景**：`M10尾帧.png` 高斯模糊（radius=9）+ 全局暗化遮罩（alpha=70）+ 右半追加轻遮罩（alpha=30），整体明亮温暖。**手机截图**：等比缩放至高 670px，圆角裁切（radius=18）+ 投影 + 白色描边，居中置于左半（px=(640−pw)/2）。**右侧文字**：主标题白色（字号 50）+ 装饰横线 + 副标题灰蓝色（字号 29），整体垂直居中于右半（cx=960）。**Tag**：底部固定位置（y=620）琥珀金胶囊形「更多功能已上线」，白色字 |
| 功能文案 | `小红书_1`：主「**一键发布小红书**」· 副「AI生图，树洞文案」<br>`小红书_2`：主「编辑后跳转发布」· 副「复制文案 · 唤起小红书」<br>`周报_1`：主「周报 / 月报 / 年报」· 副「数据就绪 · 一键生成」<br>`周报_2`：主「AI 成长观察报告」· 副「行为归纳 · 养育建议」 |
| 音效 | 静音（延续 M10 渐弱尾音直至静默） |
| 音乐 | 延续镜头 10 尾音渐弱至静默；不再起新主题 |
| 剪辑衔接 | 家庭版1（产品功能示意图 4s）末尾直切入本镜第一张；两大段（小红书→周报）之间硬切 |
| 制作要点 | 合成图由 `Python + Pillow` 生成于 `0617/output/*_split.png`，再由 FFmpeg 转为 60fps 2s 视频，经 `xfade` 组合为 `seg_xhs_with_fadeout.mp4`（小红书段）和 `seg_zb.mp4`（周报段） |
| 备注 | 合成图源文件：`小红书_1_split.png`、`小红书_2_split.png`、`周报_1_split.png`、`周报_2_split.png`（均在 `0617/output/`）；对应视频：`v4_seg/M11_xhs1_v4.mp4`、`normalized/M11_小红书_2.mp4`、`v4_seg/M11_zb1_v4.mp4`、`normalized/M11_周报_2.mp4` |

---

## 三、AI 生图提示词（Image Prompts）

> 每个镜头均提供「中文提示词」+「English Prompt」，并按统一七要素结构编写，便于直接喂给生图模型：
> **① 风格限定 · ② 视角构图 · ③ 主题描述 · ④ 背景设定 · ⑤ 细节修饰 · ⑥ 光影色调 · ⑦ 质量词**
>
> **重要 · 真人实拍风格**：本片全部画面与视频为**真人实拍写实风格**，请在每条提示词中保持 `photorealistic, live-action, shot on cinema camera (ARRI Alexa), real human actors, natural skin texture` 等关键词，避免出现动画/插画/卡通/3D 渲染感。
> **统一风格串（Style Token，可拼接到任意一条）**：`photorealistic, live-action film still, shot on ARRI Alexa, 35mm lens, cinematic warm storytelling, real human actors, natural skin texture, shallow depth of field, soft volumetric light, subtle film grain, 2.39:1 anamorphic`
> **统一负向串（Negative Token，避免动画感）**：`anime, cartoon, illustration, 3D render, CGI, painting, drawing, plastic skin, doll-like, video game`
> **统一质量串（Quality Token）**：`masterpiece, best quality, ultra-detailed, 8K, sharp focus, professional color grading, highly detailed textures, award-winning cinematography`

### 镜头 01 — 书桌前的专注
- **中文**：
  - **风格限定**：真人实拍写实风格（photorealistic / live-action，非动画非插画），温暖治愈系电影质感
  - **视角构图**：中近景，过门框向内的缓推机位，2.39:1 宽银幕构图，主体居中偏右
  - **主题描述**：一个男孩坐在书桌前低头专注地写数学作业，**左手腕**戴着智能手环（**屏幕全黑、不发光**）
  - **背景设定**：夜晚温馨书房，墙面贴着儿童画与课程表，书架与窗帘虚化于背景
  - **细节修饰**：书桌一角静静坐着一只圆润可爱、未发光的毛绒玩具，铅笔、草稿纸、橡皮、台灯齐备。台灯下放着星星机器人。
  - **光影色调**：暖黄台灯为唯一光源，柔和暖调，背景化为温柔光斑，浅景深
  - **质量词**：杰作，超精细，8K，锐利对焦，电影级调色
- **EN**: `(style) photorealistic live-action film still, shot on ARRI Alexa with a 35mm lens, real human child actor, natural skin texture, cinematic warm healing realism (not anime, not illustration, not 3D render); (composition) medium-close shot, slow push-in framed through a doorway, 2.39:1 widescreen, subject slightly right of center; (subject) a boy sitting at a desk, head down, focused on math homework, a smart wristband on his left wrist with a completely dark, off screen (not glowing, silent); (background) a cozy study room at night, children's drawings and a timetable on the wall, blurred bookshelf and curtains; (details) a cute round soft plush toy sitting quietly at the corner of the desk (not glowing), pencil, draft paper, eraser, desk lamp; (light & color) warm yellow desk lamp as the only light source, gentle warm tones, background melting into soft bokeh, shallow depth of field; (quality) masterpiece, ultra-detailed, 8K, sharp focus, professional color grading`

### 镜头 02 — 难题来袭 · 焦虑萌芽
- **中文**：
  - **风格限定**：真人实拍写实风格（photorealistic / live-action，非动画非插画），微距电影质感，略带不安情绪氛围
  - **视角构图**：手部特写（微距），轻微手持俯角，浅景深聚焦笔尖与草稿纸
  - **主题描述**：男孩握铅笔的手停顿在草稿纸上方，指节微微收紧，透出迟疑与焦虑；**左手手腕入镜，戴着智能手环，手环屏幕全黑、不发光**
  - **背景设定**：同一书桌台面，背景的作业本与台灯严重虚化
  - **细节修饰**：草稿纸上写满又被划掉的算式，橡皮屑散落，铅笔尖有磨损痕迹；**左手腕的智能手环屏幕纯黑、无任何显示与亮光**
  - **光影色调**：色温转冷、光线压暗，青灰冷调，对比加强营造压迫感
  - **质量词**：杰作，超精细，8K，纹理细腻，锐利对焦
- **EN**: `(style) photorealistic live-action film still, shot on ARRI Alexa, real human actor, natural skin texture, cinematic realism, macro texture, subtly uneasy mood (not anime, not illustration, not 3D render); (composition) extreme close-up of hands, slight handheld high angle, shallow depth of field on the pencil tip and paper; (subject) a boy's hand gripping a pencil, frozen above the draft paper, knuckles slightly tense, showing hesitation and anxiety, his left wrist in frame wearing a smart wristband with a completely black, off screen (not glowing); (background) the same desk surface, workbook and lamp heavily blurred; (details) draft paper full of written and crossed-out equations, eraser crumbs scattered, worn pencil tip, the left-wrist wristband screen pure black with no display or light; (light & color) cooler color temperature, dimmed light, cyan-gray cool grade, increased contrast for pressure; (quality) masterpiece, ultra-detailed, 8K, fine textures, sharp focus`

### 镜头 03 — 心率飙升 · 静默后台示警（空中悬浮可视化）
- **中文**：
  - **风格限定**：真人实拍写实 + 科幻全息 UI 合成（非动画），克制冷峻的科技氛围
  - **视角构图**：手腕微距起幅后拉上摇，揭示手腕上方的悬浮全息，浅景深
  - **主题描述**：男孩**左手腕**戴着一只**屏幕全黑、毫无显示**的智能手环（强调静默），**左手腕**上方**空中悬浮半透明全息心率可视化**
  - **背景设定**：昏暗书房书桌一角，背景极度虚化以突出全息光效
  - **细节修饰**：跳动的心率波形与大号数字"115"，一条横亘的红色阈值线，数值冲破红线处波形由青蓝转为警示红，细微的全息扫描线与粒子
  - **光影色调**：环境冷暗，全息发出青蓝冷光、越界处转为警示红，光晕悬浮空中
  - **质量词**：杰作，超精细，8K，发光细节精致，锐利对焦
- **EN**: `(style) photorealistic live-action film still, real human actor, natural skin texture, fused with sci-fi holographic UI VFX, restrained cool tech mood (not anime, not cartoon, not 3D render); (composition) macro on the left wrist then pull-back and tilt-up revealing a floating hologram above the left wrist, shallow depth of field; (subject) a boy's left wrist wearing a smart wristband with a completely dark, blank screen (silent, no display), while a translucent holographic heart-rate visualization hovers in mid-air above the left wrist; (background) a dim study desk corner, heavily blurred to emphasize the holographic glow; (details) a pulsing heart-rate waveform and a large number "115", a horizontal red threshold line, the waveform turning from cyan to alert-red where it crosses the line, subtle holographic scan-lines and particles; (light & color) dim cool environment, hologram emitting cyan-blue light shifting to alert-red at the breach, glow floating in air; (quality) masterpiece, ultra-detailed, 8K, refined glow details, sharp focus`

### 镜头 04 — 信号触发 · 父母端关怀提醒
- **中文**：
  - **风格限定**：真人实拍 + 电影级 VFX 合成的概念可视化（非动画），**冷静克制的科技感**过渡至温情电影质感，朴实不炫技
  - **视角构图**：**同镜两段式**（**不穿墙**）——前半为孩子左手腕手环微距特写，细光线升起后**镜头跟随光线转入**父母手机特写；后半固定俯拍，手机上方悬浮全息关怀气泡框为视觉焦点
  - **主题描述**：心率达到 115 时，**一道纤细的数据光线**从男孩**左手腕的手环**升起（**手环黑屏不发光**）；**同镜内**光线汇入客厅沙发上妈妈手中的手机，手机亮屏震动，屏幕上方升起**半透明全息关怀气泡框**（琥珀金光，由细光丝与手机相连）
  - **背景设定**：前段暗调夜晚儿童书房书桌一角（暖黄台灯）；后段夜晚温暖客厅沙发区（窗外漆黑、落地灯/壁灯），父母并肩而坐，父亲身影虚化于背景
  - **细节修饰**：**细线状发光数据光线，纤细锐利、笔直简洁**；仅有极少量微弱光点，**不要丝带、不要华丽粒子拖尾**；后段全息气泡悬浮于手机上方空气中（气泡文字后期贴图），气泡边缘有细微扫描线与粒子，手机轻微动态模糊暗示震动
  - **光影色调**：前段暗调中细光线发光、冷青起；后段客厅暖光偏暗，气泡发**温暖琥珀金光**（区别于镜头 03 警示红），气泡光与屏光映在母亲脸上，冷暖柔和对比
  - **质量词**：杰作，超精细，8K，光效与全息气泡精致，锐利对焦
- **EN**: `(style) photorealistic live-action with cinematic VFX composited in, semi-abstract conceptual visualization, calm restrained high-tech mood transitioning to tender realism (not anime, not cartoon); (composition) single-shot two-part (no wall-cut): first a macro close-up of the boy's left-wrist wristband, a thin light line rising, the camera following the line into a close-up of the parents' smartphone; second part a slight high-angle fixed shot with a translucent holographic care-bubble floating above the phone as focal point; (subject) as heart rate hits 115, a thin straight glowing data line rises from the left-wrist wristband (completely black, not glowing); in the same shot the line merges into the mother's smartphone on the living-room sofa, the phone lighting up and gently vibrating while a translucent amber holographic care-bubble rises above the screen, tethered by a thin thread of light; (background) first a dim study desk corner, then a warm living-room sofa at night with pitch-black windows; (details) a thin, sharp, minimal glowing data line with only a few faint light points, NO ribbon, NO ornate particle trails; then a translucent holographic bubble above the phone (empty for post-production text), faint scan-lines, subtle phone motion blur hinting vibration; (light & color) dark grade with thin line glowing cool-to-warm, then dim warm living-room light with an amber care-bubble (not alert-red), bubble and screen glow on the mother's face; (quality) masterpiece, ultra-detailed, 8K, restrained light effect and luminous hologram, sharp focus`

### 镜头 05 — 父母反馈 · 腾讯云生成关怀方案
- **中文**：
  - **风格限定**：真人实拍写实 + 科技未来感概念 VFX 合成（非动画卡通），温情电影质感过渡至云端数字空间
  - **视角构图**：**同镜两段式**——前半为手机屏幕特写（过肩视角），软键盘与输入框占据画面下半部；发送后镜头跟随自手机升起的细光线转入抽象数字空间全景，后半缓慢环绕推进至中心光核，对称放射式构图
  - **主题描述**：父母坐在客厅沙发上，母亲的拇指在 App 文本输入框中**逐字输入"他正在写数学作业"**并发送；发送瞬间一道**纤细丝滑曲线光线**自手机升起，**同镜内**汇入中央发光光球（**腾讯云 AI**），分析场景并经 MQTT 下发指令，分两束光线指向毛绒玩具与星星机器人图标
  - **背景设定**：前段为夜晚温暖客厅沙发区（窗外漆黑、暖色落地灯/壁灯），父亲关切探看；后段为深蓝色抽象数据宇宙，漂浮的数据节点与网格
  - **细节修饰**：前段 App 场景反馈页含文本输入框、弹起软键盘、闪烁光标、高亮发送按钮；后段光核上方隐约浮现"腾讯云 / Tencent Cloud"字样，金色数据光点汇入，MQTT 指令分流光束；全程以一道**纤细丝滑 S 形曲线光线**串联（与镜头 04 同款光线风格）
  - **光影色调**：前段夜景室内暖光与屏幕光交融；后段深蓝冷底 + 金色暖光点，科技辉光与温情过渡
  - **质量词**：杰作，超精细，8K，界面与光效精致，锐利对焦
- **EN**: `(style) photorealistic live-action film still fused with futuristic conceptual VFX, tender realistic cinematic transitioning into a digital cosmos (not anime, not cartoon); (composition) single-shot two-part: first an over-the-shoulder close-up of a smartphone with keyboard and input box filling the lower half, then the camera follows a thin silky curved line of light rising from the phone into a wide abstract digital space, slow orbit-in to a symmetrical radial core; (subject) the parents on the living-room sofa, the mother's thumb typing "he is doing math homework" into an app text input box and sending, the father leaning in with concern; at sending, a thin silky S-curve data line rises from the phone and merges into a central glowing orb (Tencent Cloud AI) analyzing the scene and dispatching commands via MQTT, splitting into two beams toward plush-toy and star-robot icons; (background) first a warm living-room sofa area at night, then a deep-blue abstract data cosmos with floating nodes and grids; (details) first part: app feedback page with text field, soft keyboard, blinking cursor, highlighted send button; second part: faint "Tencent Cloud" wordmark above the core, golden particles flowing in, MQTT command beams branching out; one continuous thin silky curved light line throughout (same style as shot 04); (light & color) warm room and screen glow in the first part, deep-blue cool base with golden warm particles in the second; (quality) masterpiece, ultra-detailed, 8K, legible UI and refined glow, sharp focus`

### 镜头 06 — 星星机器人 · 温柔开口
- **中文**：
  - **风格限定**：真人实拍写实风格（非动画非插画），温暖治愈系电影质感，可爱科技产品实物质感
  - **视角构图**：中近景双主体，机器人与男孩侧脸同框，浅景深
  - **主题描述**：焦虑中的男孩身旁，一道**纤细丝滑曲线光线**自画面外飘入、汇入桌面星星机器人，机器人随之被唤醒、率先亮起，主动开口安抚说话，男孩抬头好奇地看着它
  - **背景设定**：夜晚书房书桌，仍偏冷暗、暖意刚起，背景虚化
  - **细节修饰**：一道的**纤细丝滑、划出柔和曲线（S 形、非直线）的科技感数据光线**自画面外接入机器人本体、没入机身;机器人的柔光眼神与微笑像素表情成为画面第一缕暖意，机器人圆润外壳的高光，男孩从紧绷转好奇的神情
  - **旁白/字幕**：（机器人台词·特教老师般温柔女声）"小主人，写作业累了吧？别急——我们先和毛绒玩具一起，深呼吸三次吧。"
  - **光影色调**：以冷调为主、机器人面屏柔光与那道细光线点缀开始引入第一缕暖意，温馨治愈
  - **质量词**：杰作，超精细，8K，产品质感精致，锐利对焦
- **EN**: `(style) photorealistic live-action film still, shot on ARRI Alexa, real human actor, natural skin texture, warm healing cinematic realism, real physical tech product (not anime, not cartoon, not 3D render); (composition) medium-close two-subject shot, the robot's face screen and the boy's profile in one frame, shallow depth of field; (subject) beside the anxious boy, a single thin silky curved line of light flows in from off-frame and merges into the star-faced companion robot on the desk, waking it so it lights up first with a gentle smiling expression and starts to speak soothingly, the boy looking up at it curiously; (background) the night study desk, still cool and dim with warmth just beginning, blurred behind; (details) a thin, silky, gently curving (S-curve, not straight) high-tech data line, same style as shot 05, flowing in from off-frame into the robot's body and sinking into it (restrained and not flashy, NO Tencent Cloud wordmark / logo / any text); soft glowing eyes and a smiling pixel expression on the star screen as the first hint of warmth in frame, highlights on the robot's rounded shell, the boy's expression turning from tense to curious; (light & color) predominantly cool tones with the robot's soft face glow and the thin light line introducing the first hint of warmth, heartwarming; (quality) masterpiece, ultra-detailed, 8K, refined product texture, sharp focus`

### 镜头 07 — 毛绒玩具点亮 · 一起呼吸
- **中文**：
  - **风格限定**：真人实拍写实风格（非动画非插画），温暖治愈系电影质感，柔焦氛围
  - **视角构图**：毛绒玩具特写起幅，随光亮缓缓后拉带出男孩的脸，转呼吸式极缓推拉机位，浅景深
  - **主题描述**：应机器人之邀，桌面上的毛绒玩具瞬间从内部亮起治愈的琥珀色暖光，光晕随呼吸节奏一胀一缩；男孩闭眼跟着光的节奏深呼吸、肩膀放松，人与光同频
  - **背景设定**：夜晚书房书桌，整体由冷转暖、沐浴在柔和暖光中，背景虚化为温柔光斑
  - **细节修饰**：柔和光晕在桌面晕染开、脉动边缘柔化，毛绒纤维被暖光勾勒出绒毛质感，男孩脸被柔光照亮、肩膀放松下沉、胸口随呼吸起伏
  - **光影色调**：全片色温转折点——由冷青转为琥珀暖金，柔焦光晕弥漫整个画面，宁静温暖治愈
  - **质量词**：杰作，超精细，8K，绒毛与氛围光质感细腻，锐利对焦
- **EN**: `(style) photorealistic live-action film still, shot on ARRI Alexa, real human actor, natural skin texture, warm serene healing cinematic realism, soft-focus atmosphere (not anime, not illustration, not 3D render); (composition) close-up of the plush toy as the opening frame, slow pull-back revealing the boy's face, transitioning into an extremely slow breathing-style push-pull, shallow depth of field; (subject) answering the robot's invitation, the plush toy on the desk suddenly glowing with healing amber warm light from within, its halo expanding and contracting in sync with the breath, the boy breathing deeply with eyes closed in rhythm with the light, shoulders relaxing; (background) the night study desk shifting from cool to warm, bathed in soft warm light, melting into gentle bokeh; (details) a soft halo spreading across the desk with softened pulsing edges, fuzzy fibers rim-lit by warm light showing plush texture, the boy's face lit by the glow, shoulders lowering, chest rising and falling with breath; (light & color) the film's color-temperature turning point — shifting from cool cyan to amber warm gold, diffuse soft-focus glow filling the frame, calm warm and healing; (quality) masterpiece, ultra-detailed, 8K, delicate plush and ambient light texture, sharp focus`

### 镜头 08 — 对话解困 · 一起面对难题
- **中文**：
  - **风格限定**：真人实拍写实风格（非动画非插画），温暖治愈系电影质感，可爱科技产品实物质感
  - **视角构图**：中近景双主体，星星机器人面屏与男孩同框（正反打感），浅景深
  - **主题描述**：平静下来的男孩转向桌面星星机器人，指着作业本说出自己卡住的难题，机器人面屏以温柔微表情回应、引导他一起拆解
  - **背景设定**：夜晚书房书桌，已被暖光笼罩，毛绒玩具柔光陪伴于侧，背景虚化
  - **细节修饰**：男孩边说边皱眉又渐舒展、手指点向作业本上划掉的算式，星形面屏点头/眨眼的微笑像素表情，**左手腕**智能手环**屏幕全黑、不发光**
  - **光影色调**：暖光环绕，温馨治愈，机器人面屏柔光点缀，浅景深
  - **质量词**：杰作，超精细，8K，表情自然生动，锐利对焦
- **EN**: `(style) photorealistic live-action film still, shot on ARRI Alexa, real human actor, natural skin texture, warm healing cinematic realism, real physical tech product (not anime, not illustration, not 3D render); (composition) medium-close two-subject shot, the star robot's face screen and the boy in one frame (shot-reverse-shot feel), shallow depth of field; (subject) the calmed boy turning to the star-faced robot on the desk, pointing at his workbook and telling it the problem he's stuck on, the robot's face responding with gentle micro-expressions and guiding him to break it down together; (background) the night study desk now bathed in warm light, the plush toy glowing softly beside him, blurred behind; (details) the boy frowning then gradually relaxing as he speaks, his finger pointing at a crossed-out equation, nodding/blinking smiling pixel expressions on the star screen, the smart wristband on his left wrist with a completely black, off screen (not glowing); (light & color) surrounded by warm light, heartwarming, soft glow accents from the robot's face, shallow depth of field; (quality) masterpiece, ultra-detailed, 8K, natural lively expression, sharp focus`

### 镜头 09 — 茅塞顿开 · 继续作业
- **中文**：
  - **风格限定**：真人实拍写实风格（非动画非插画），温暖治愈系电影质感
  - **视角构图**：中近景，轻微推近至笔尖落纸的瞬间，浅景深
  - **主题描述**：男孩忽然想通解法、眼睛一亮，开心自信地写下答案，神情舒展
  - **背景设定**：夜晚书房书桌，毛绒玩具与机器人柔光陪伴于侧，背景虚化
  - **细节修饰**：眼睛一亮的恍然神情、嘴角上扬的微笑，笔尖在纸上流畅书写，先前划掉的算式旁写下新的解答，**左手腕**智能手环**屏幕全黑、不发光**
  - **光影色调**：暖光环绕，明亮安定，治愈温暖，浅景深
  - **质量词**：杰作，超精细，8K，表情自然生动，锐利对焦
- **EN**: `(style) photorealistic live-action film still, shot on ARRI Alexa, real human actor, natural skin texture, warm healing cinematic realism (not anime, not illustration, not 3D render); (composition) medium-close shot, slight push-in to the moment the pencil tip touches the paper, shallow depth of field; (subject) the boy suddenly getting it, eyes lighting up, happily picking up his pencil again and confidently writing the answer, expression relaxed; (background) the night study desk, the plush toy and robot glowing softly beside him, blurred behind; (details) an "aha" look with brightening eyes, a slight upturned smile, the pencil flowing smoothly on paper, a new solution written next to the previously crossed-out equations, the smart wristband on his left wrist with a completely black, off screen (not glowing); (light & color) surrounded by warm light, bright and stable, healing warmth, shallow depth of field; (quality) masterpiece, ultra-detailed, 8K, natural lively expression, sharp focus`

### 镜头 10 — 心率归于平静 · 收尾全景
- **中文**：
  - **风格限定**：真人实拍写实风格（非动画非插画），温情收尾的电影质感
  - **视角构图**：手机屏幕特写起幅，大幅后拉至剖面式两房间全景，2.39:1 宽银幕
  - **主题描述**：客厅沙发上的父母手机 App 上心率曲线由红色高峰平复回落至绿色平静区间，随后镜头拉远呈现"一墙之隔却紧紧相连"的一家
  - **背景设定**：夜晚剖面建筑（两侧窗外皆为夜色），左侧男孩书房·暖黄台灯，右侧父母客厅沙发区·暖色落地灯，父母并肩坐在沙发上，同处一片夜晚室内暖光
  - **细节修饰**：App 曲线平复并显示"已恢复平静 ❤"，孩子在书房继续写作业，父母坐在客厅沙发上安心相视，落版预留 Logo + Slogan 空间
  - **光影色调**：通体温暖金光，柔和均匀，安定治愈，宽银幕电影感
  - **质量词**：杰作，超精细，8K，构图工整，锐利对焦
- **EN**: `(style) photorealistic live-action film still, shot on ARRI Alexa, real human actors, natural skin texture, tender closing cinematic realism (not anime, not illustration, not 3D render); (composition) close-up of a phone screen as opening frame, large pull-back to a cross-section view of two rooms, 2.39:1 widescreen; (subject) the app's heart-rate curve falling from a red peak back into a calm green zone on the parents' phone as they sit on the living-room sofa, then the camera pulling back to reveal a family connected across a single wall; (background) architectural cross-section, the boy's study on the left and the parents' living-room sofa area on the right, parents seated side by side on the sofa, sharing the same warm light; (details) the curve settling with a "calm restored ❤" label, the boy continuing homework in the study, the parents sitting on the sofa and exchanging a reassured look, reserved space for an end-card logo + slogan; (light & color) warm golden light throughout, soft and even, calm and healing, widescreen cinematic; (quality) masterpiece, ultra-detailed, 8K, clean composition, sharp focus`

### 镜头 11 — 功能说明 · 四格真机截图（成片不用 AI 出界面）

> **成片素材**：第二章已规定为 **`小红书_1` → `小红书_2` → `周报_1` → `周报_2`** 四张真机截屏，各 **2s**、**16:9** 序列内剪辑，**无需文生图 / 即梦**。下列提示词仅在**缺素材、需补占位底图**时使用（灰屏手机框 + 虚化尾帧），**勿用 AI 生成带假字的小程序界面**。

- **中文**：
  - **风格限定**：真人实拍合成参考（与镜头 10 尾氛围衔接），非动画
  - **视角构图**：16:9 画幅；可选前景手机框约占 **35–45%**，或全屏留白底
  - **主题描述**：占位用——手握手机，**屏区浅灰 / 高光反射、无 UI**；正式成片以**第二章「镜头 11」**表为准，直接贴入四张真机截图
  - **背景设定**：可选镜头 10 同场景**强虚化**暖金光斑底
  - **细节修饰**：金属边框与玻璃反光即可；**负向**：假 App 文字、假图表
  - **光影色调**：暖金散景 + 屏面冷反射
  - **质量词**：前景边缘锐利、底图虚化干净
- **EN**: `(style) photorealistic live-action composite plate for emergency use only; (composition) 16:9, optional smartphone frame 35–45% foreground or full-frame neutral plate; (subject) phone screen is flat neutral gray or soft specular reflection ONLY — NO fake UI; (background) optional heavily blurred warm golden bokeh from shot 10 ending; (quality) sharp bezel, clean blur; negative: fake UI text, charts, watermarks`

---

## 四、制作备注（Production Notes）

- **时长预算（实际成片约 81.5 秒）**：片头字幕卡 3s + 黑场 0.5s + ①4s + ②5s + ③7s + ④7s + ⑤10s + ⑥8s + ⑦6s + ⑧6s + ⑨5s + ⑩5s（含冻帧 2s）+ M10淡出 2s + 家庭版1 4s + **⑪7.4s（小红书段 3.7s + 周报段 3.7s）**。三段节奏：**铺垫与焦虑**（01–03）→ **信号流转与介入**（04–05）→ **陪伴·对话·平复**（06–10）→ **功能落版**（⑪）。如需压缩，可砍镜头 04 约 1–2s 或删除整段 ⑪；如需延长，在 ⑦⑩ 各加 2–3s。
- **镜头 ⑪（约 7.4s）**：采用 **FFmpeg + Pillow** 生成「左手机右文字」split 合成图方案——顺序 **`小红书_1`→`小红书_2`（叠化 0.3s）→ 淡出 → 硬切 → `周报_1`→`周报_2`（叠化 0.3s）**；功能文案已烘焙于合成图中（见第二章镜头 11 表）。成片可删本镜保留 10 镜纯叙事版。
- **声音设计要点**：孩子端始终"无打扰"——手环无震动、报警声只出现在父母端。声音的"缺席"本身就是叙事，请在镜头03刻意做静默处理。
- **旁白声线统一**：全片**画外旁白**（镜头 04 / 05 / 10 等）由**同一位温柔女声**录制，气质知性、语速略慢、气息稳定；与星星机器人台词女声可同属一类声线或略偏「叙述感」以区分角色对白与旁白。
- **色彩转场**：镜头01→03 冷化下降；镜头06 星星机器人面屏柔光引入"第一缕暖意"（仍偏冷），镜头07 毛绒玩具琥珀光点亮处完成全片色温转折（冷→暖），务必让这束琥珀光成为情绪拐点。
- **432Hz 音乐**：从镜头05 前导动机 → 镜头06 正式进入 → 镜头09 高潮 → 镜头10 收束，保持同一主题的三段式发展（镜头08 对话解困处旋律温暖延展铺垫）；**镜头 11** 为合成信息镜，仅**延续 10 的渐弱尾音**或静场 + 极轻 UI 音。
- **云端品牌一致性**：实现方案云端统一采用**腾讯云**。镜头04 信号传递、镜头05 云端处理、镜头10 数据回流，凡涉及"云端"的可视化均以腾讯云为准；镜头05 可在光核上方隐现"腾讯云 / Tencent Cloud"字样或 Logo，链路按 **腾讯云 IoT Hub + MQTT 下发指令** 呈现，全片云端措辞统一为"腾讯云"。
- **竖版改编**：若做 9:16 社媒版，优先保留镜头 03 / 06 / 07 / 10 / **11**，并强化字幕。
- **落版 Slogan 备选**：①"最好的科技，是让爱准时抵达。" ②"看不见的守护，听得见的温柔。" ③"当焦虑来临，光，先到了。"

### 转场设计方案（v5 剪辑备注）

> 以下为 **v5 最终成片实际执行**的转场方案，已结合叙事节奏与情绪弧线深度讨论确定并通过多轮调整落地。  
> 整体节奏律：**字幕卡淡出 → 黑场停顿启幕 → 呼吸感段落切换 → 叠溶渗透张力段 → M07 慢淡出沉淀 → 硬切强调顿悟 → 黑场分隔 → 冻帧信息停留 → 慢淡出收尾 → 硬切明快功能展示**

| # | 切点 | 转场类型 | 参数（实际执行） | 电影剪辑语言 |
|---|------|----------|-----------------|-------------|
| 0a | **TITLE 内部** | 淡出（烘焙在 TITLE 末尾） | 淡出 0.5s | 字幕卡柔和退场 |
| 0b | **TITLE → M01** | 黑场停顿 + M01 淡入 | 黑场 0.5s + 淡入 0.4s | **段落感开场，留白启幕，仪式感** |
| 1 | **M01 → M02** | 淡出→黑场→淡入 | M01 淡出 0.5s + M02 淡入 0.5s | **电影级段落切换，黑场呼吸停顿，暗示时间流逝，焦虑萌芽** |
| 2 | **M02 → M03** | 叠化 | 0.3s | **柔和叠溶，画面在情绪中渗透，内心觉察非外部冲击** |
| 3 | **M03 → M04** | 叠化 | 0.4s | **全息光晕溶入手腕特写，科技无声消融，温柔渗透感** |
| 4 | **M04 → M05** | 快速叠化 | 0.2s | **轻盈呼吸切，动作连贯，从接收警报到即时响应** |
| 5 | **M05 → M06** | 叠化 | 0.3s | **跨空间信号传递，数据流动感，场景柔和跨越** |
| 6 | **M06 → M07** | 硬切 | — | **干脆直接，不留余地，强调毛绒玩具瞬间亮起的即时性** |
| 7 | **M07 结尾** | 末尾 1s 渐黑淡出（烘焙在 M07_v4） | 淡出 1.0s（不缩短原片时长） | **呼吸节奏感，深呼吸余韵，与对话场景之间的空气感停顿** |
| 8 | **M08 开场** | 淡入（烘焙在 seg_M08_M09 开头） | 淡入 0.4s | **柔和进入，从余韵中自然唤起对话** |
| 9 | **M08 → M09** | **硬切** | — | **干脆切换，茅塞顿开的即时感，区别于长叠化导致的重影问题** |
| 10 | **M09 结尾** | 淡出（烘焙在 seg_M08_M09 末尾） | 淡出 0.5s | **顿悟余韵，收笔前的短暂呼吸** |
| 11 | **M09 → M10** | 黑场分隔 + M10 冻帧开场 | 黑场（M09淡出尾）+ 冻帧停留 2.0s + 叠化 0.3s | **黑场分隔空间，冻帧给观众充分时间读清手机屏幕，柔和展开主镜** |
| 12 | **M10 结尾** | 尾帧渐黑过渡片段（额外生成） | 2.0s 渐黑 | **电影级慢淡出，情绪弧自然收尾，不截断 M10 原有节奏** |
| 13 | **黑场 → 家庭版1** | 淡入（烘焙在 家庭版1_v4 开头） | 淡入 0.4s | **从黑场柔和渐现，章节翻页感，从情绪叙事切换到功能展示** |
| 14 | **家庭版1 → M11 首图** | 硬切 | — | **功能说明段落内部，信息直达，节奏简洁明快** |
| 15 | **M11 小红书段内部**（`小红书_1`→`小红书_2`） | 叠化 | 0.3s | **同主题连贯展示，轻盈衔接** |
| 16 | **M11 小红书段结尾** | 淡出（烘焙在 seg_xhs_with_fadeout 末尾） | 淡出 0.35s | **段落间轻柔收口** |
| 17 | **M11 小红书段→周报段** | 硬切 | — | **功能模块切换，信息优先** |
| 18 | **M11 周报段内部**（`周报_1`→`周报_2`） | 叠化 | 0.3s | **同主题连贯展示，轻盈衔接** |

#### v5 额外生成的过渡片段

| 片段名 | 路径 | 时长 | 帧率 | 用途 |
|--------|------|------|------|------|
| `TITLE.mp4` | `normalized/` | 3.0s | 60fps | 片头字幕卡（白字双行 + 末尾 0.5s 淡出） |
| `black_0.5s.mp4` | `v4_seg/` | 0.5s | 60fps | TITLE 与 M01 之间的黑场停顿 |
| `M10_freeze.mp4` | `v4_seg/` | 2.3s | 60fps | M10 第一帧静止（2.0s 纯冻帧 + 0.3s xfade 预留） |
| `M10_fadeout.mp4` | `v4_seg/` | 2.0s | 60fps | M10 最后一帧 2.0s 全程渐黑，情绪自然收束 |
| `M07_v4.mp4` | `v4_seg/` | 6.0s | 60fps | M07 原片 + 末尾 1s 淡出（不缩短原时长） |
| `seg_M08_M09.mp4` | `v4_seg/` | 11.1s | 60fps | M08（淡入 0.4s）+ 硬切 + M09 + M09（淡出 0.5s） |
| `家庭版1_v4.mp4` | `v4_seg/` | 4.0s | 60fps | 产品功能示意图（开头淡入 0.4s） |
| `seg_xhs_with_fadeout.mp4` | `v4_seg/` | 3.7s | 60fps | 小红书段：`小红书_1`→`小红书_2` 叠化 0.3s + 末尾淡出 0.35s |
| `seg_zb.mp4` | `v4_seg/` | 3.7s | 60fps | 周报段：`周报_1`→`周报_2` 叠化 0.3s |

#### M11 合成底图说明（v5 最终版）

M11 四张截图采用**「左手机右文字」split 双层合成**：
- **背景**：`0617/M10尾帧.png` 高斯模糊（radius=9）+ 全局暗化遮罩（RGBA alpha=70）+ 右半追加轻遮罩（alpha=30），背景明亮温暖可辨
- **手机截图（左半）**：等比缩放至高 670px，圆角裁切（radius=18），投影（offset=10×10，blur=10，alpha=140），白色描边（width=2，alpha=80），横向居中于左半 0–640px 区域
- **功能文案（右半）**：主标题白色（字号 50，带 2px 投影）+ 细装饰横线 + 副标题灰蓝色（字号 29），整体垂直居中于右半（cx=960）
- **Tag**：底部固定（y=620），琥珀金圆角胶囊（RGBA 220,155,50,210）内白色「更多功能已上线」（字号 22）
- **中间分隔线**：x=648 竖线，alpha=60，高度 120–600px
- 合成图输出路径：`0617/output/*_split.png`；对应视频：`v4_seg/M11_xhs1_v4.mp4`、`normalized/M11_小红书_2.mp4`、`v4_seg/M11_zb1_v4.mp4`、`normalized/M11_周报_2.mp4`

---

## 五、人物设定（Character Design / 角色设定集）

> 用于角色一致性参考（Character Reference Sheet）。每个角色包含：**外形 / 服装 / 性格 / 情绪 / 行为特点**，
> 并附「角色定妆 AI 生图提示词」（中文 + English），建议生成 **角色定妆参考图 + 表情包** 作为统一参考图，
> 后续各镜头用同一套描述词锁定角色，避免脸型、发型、服装漂移。
> 注：本节不含画面清晰度/质量词（如 8K、超精细等），生成时由模型自主选择。
> **风格要求**：全部角色为**真人实拍写实风格**（photorealistic / live-action，真人演员、自然皮肤质感），**非动画、非插画、非 3D 渲染**。
> 建议负向词：`anime, cartoon, illustration, 3D render, CGI, plastic skin, doll-like`。

### 角色 01 — 朗朗（男孩 · 主角）
| 维度 | 设定 |
|------|------|
| 外形 | 中国男孩，9–10岁（小学三年级），偏瘦小、圆脸，黑色整洁短发带少量刘海（因不自觉抓挠略显蓬松凌乱），深褐色大眼睛清澈灵动、眼神难以长时间聚焦，肤色暖黄健康，神态机灵好动、身体藏不住"坐不住"的劲头 |
| 服装 | 夏季居家休闲装：浅米色/燕麦色圆领**短袖纯棉 T 恤**（领口因常被拉扯而略松垮） + 深灰色**休闲短裤**（裤边随意） + **短棉袜**（袜口下滑至脚踝）或室内棉拖；**左手腕**佩戴一只简约的智能手环（**绿色硅胶表带、规则圆孔、竖向胶囊形圆角矩形屏幕**；**全程黑屏、不发光、静默无显示**） |
| 性格 | **活泼好动、精力旺盛、好奇心强**，注意力易被新鲜事物吸引而分散，对感兴趣的事能短暂高度投入；抗挫力偏弱，遇到难题容易急躁、自我施压，伴随大量无意识的小动作 |
| 情绪 | 全片情绪弧线：好动中短暂专注 → 分心急躁 → 紧张无助（小动作加剧） → 被陪伴安抚（躁动逐渐平复） → 释然咧嘴笑；情绪外放、来得快去得也快，多体现在眉眼、坐姿、肢体动作幅度与小动作频率的变化上 |
| 行为特点 | 平时坐不住——频繁变换坐姿、抖腿、转笔、东张西望、玩弄手边小物；写字时身体前倾、握笔偏紧；急躁焦虑时咬笔杆、反复擦改作业、抓挠头发、抖腿加剧；放松后身体舒展、长舒一口气、咧嘴笑出来 |
| **AI 生图（中文）** | 角色定妆，9–10岁活泼好动的中国男孩，偏瘦小圆脸、深褐色大眼睛清澈灵动（眼神带好动的分散感）、蓬松凌乱的黑色短发，浅燕麦色圆领短袖纯棉T恤（领口略松垮）、深灰色休闲短裤、下滑的短棉袜，左手腕戴简约智能手环（**屏幕全黑、不发光、静默无显示**），机灵好动却带轻微躁动的神情，**真人实拍写实摄影风格（真人儿童演员、自然皮肤质感，非动画非插画）**，柔和棚拍光，纯色背景，多种表情（含好动专注、急躁焦虑、放松咧嘴笑的神态及对应小动作细节） |
| **AI 生图（EN）** | `character reference, a lively and energetic 9-10-year-old Chinese boy, slim small build, round face, clear lively dark-brown eyes (an active, easily-distracted gaze), fluffy and messy short black hair, wearing an oatmeal-beige crew-neck short-sleeve cotton T-shirt (slightly loose collar), dark gray casual shorts and short cotton socks slipped to the ankles (summer outfit), a minimalist smart wristband on his left wrist (screen completely black, off and not glowing, silent), bright and restless expression, photorealistic live-action photography, real Chinese child actor, natural skin texture (not anime, not illustration, not 3D render), soft studio lighting, plain background, multiple facial expressions (including playful focus, impatient anxiety, relaxed grin and corresponding small movement details), consistent character` |

### 角色 02 — 妈妈
| 维度 | 设定 |
|------|------|
| 外形 | 约35岁中国女性，温柔知性，中长黑发自然披肩或低马尾，鹅蛋脸搭配温和笑眼，身材匀称，气质亲切治愈 |
| 服装 | 夏季居家温馨风：暖驼色/燕麦色**棉麻短袖上衣**（或同色短袖连衣裙），搭配浅色**七分/九分薄棉麻长裤**；佩戴细巧耳钉，整体色调柔和低饱和，营造清爽舒适的居家氛围 |
| 性格 | 细心敏感，富有共情力，作为家庭情绪“第一响应者”，始终冷静沉稳、不慌不乱 |
| 情绪 | 收到推送时关切且克制，无慌乱感；输入场景时专注认真；看到孩子情绪平复后露出欣慰柔和的微笑 |
| 行为特点 | 习惯性轻握手机，拇指快速轻柔打字；会下意识与孩子爸爸对视交流；动作轻缓、语气柔和 |
| **AI 生图（中文）** | 角色定妆，约35岁中国女性，温柔知性，中长黑发自然披肩，暖驼色棉麻短袖上衣配浅色薄棉麻长裤，温和笑眼，亲切治愈气质，**真人实拍写实摄影风格（真人演员、自然皮肤质感，非动画非插画）**，柔和棚拍光线，纯色背景，关切表情/微笑表情 |
| **AI 生图（EN）** | `character reference, a 35-year-old Chinese woman, gentle and intellectual, medium-long black hair naturally draped over shoulders, wearing a warm camel/oat short-sleeve linen-cotton top and light-colored thin cropped linen trousers (summer outfit), warm smiling eyes, approachable and healing aura, photorealistic live-action photography, real adult actress, natural skin texture (not anime, not illustration, not 3D render), soft studio lighting, plain background, concerned expression and smiling expression, consistent character design` |

### 角色 03 — 爸爸
| 维度 | 设定 |
|------|------|
| 外形 | 约37岁中国男性，身材偏高、肩部略宽，利落短黑发，方正温和的脸庞，可带淡淡胡青，眼神沉稳且充满可靠感 |
| 服装 | 夏季居家休闲风格：深蓝色/藏青色**圆领短袖 T 恤或短袖 Polo 衫**，搭配深色**薄棉休闲短裤或薄长裤**；无多余复杂配饰，整体简洁清爽 |
| 性格 | 沉稳内敛，行事可靠，言语不多但行动力强，是家庭里的"定海神针"般的存在 |
| 情绪 | 收到报警信息时迅速凑近屏幕，神情专注且关切；过程中通过点头、坚定的目光给予妈妈支持；事件结束后露出安心的浅笑 |
| 行为特点 | 凑近共同查看手机，动作时手扶椅背或妈妈肩膀以传递支撑；整体动作沉稳有序；更倾向于用点头、眼神等非言语方式表达态度 |
| **AI 生图（中文）** | 角色定妆，37岁左右中国男性，肩部略宽、短黑发干净利落，方正温和的脸带淡淡胡青，身着藏青色圆领短袖T恤与深色薄休闲短裤，眼神沉稳可靠，采用**真人实拍写实摄影风格（真人演员、自然皮肤质感，非动画非插画）**，搭配柔和棚拍光线，纯色背景，专注关切、安心浅笑两种表情 |
| **AI 生图（EN）** | `Character reference of a 37-year-old Chinese man with slightly broad shoulders, neat short black hair, a square gentle face with light stubble. He is wearing a navy crew-neck short-sleeve T-shirt and dark thin casual shorts (summer outfit), with a calm and reliable gaze. The style is photorealistic live-action photography, real adult actor, natural skin texture (not anime, not illustration, not 3D render), with soft studio lighting and a plain background. Include concerned expression and faint smile expression, ensuring consistent character design throughout.`|


> **关于毛绒玩具 Glow 与星星机器人 Star**：二者已有实物，将直接上传真实产品图片作为参考，**不在此生成角色设定**。
> 在 AI 生图 / 视频生成时，请以上传的实拍图为准（核心特征：毛绒玩具发治愈琥珀暖光、星星机器人为星形面屏陪伴机器人）。

### 角色一致性备注
- **国籍/年龄锁定**：全家为**中国人**；朗朗 9–10 岁（活泼好动）、妈妈约 35、爸爸约 37，生成时务必固定，避免国籍与年龄漂移。
- **时间/灯光锁定**：**全片均为同一个晚上的室内夜景**（约 20:00）。生成任何镜头都要保证：**窗外是夜色/漆黑、无日光直射**；书房唯一光源为**暖黄台灯**，客厅光源为**暖色落地灯/壁灯**等室内灯具，整体偏暗、靠灯光与屏幕光提亮人物面部，切勿出现白天天光、明亮窗光或户外日光。
- **配色锁定**：朗朗-燕麦米色、妈妈-暖驼色、爸爸-藏青色，三人服装低饱和暖调协调，便于同框。
- **道具锁定**：智能手环（深灰圆角）由 AI 生成并保持造型一致，**始终佩戴在孩子左手腕**，且**全片黑屏、不发光、静默无显示**（这是核心叙事设定，凡有手腕入镜务必保持，切勿让模型给屏幕加数字或发光）；**毛绒玩具 Glow、星星机器人 Star 以上传的实物图片为准**，在各镜头中保持与实拍一致。
- **使用建议**：先用上面的提示词各生成一张人物（朗朗/妈妈/爸爸）定妆图并锁定 seed / 参考图；毛绒玩具与星星机器人则导入实拍参考图，再在分镜生图时一并引用，以保证 **11 个镜头**里人物与道具不串味。

---

## 六、即梦（Dreamina）视频生成指南

> 即梦单段视频通常 3–5 秒，**图生视频比文生视频稳定**。推荐流水线：
> **① 文生图定首帧 → ② 图生视频加运镜 → ③ 剪映拼接配乐/旁白/字幕**。
> 真人风格务必选**写实类模型**，提示词保留 `photorealistic, live-action, real people`。

### 推荐流程（4 步）
1. **锁定一致性**：先用第五章人物定妆词生成朗朗/妈妈/爸爸参考图；毛绒玩具、星星机器**上传实拍图**。在即梦【参考图/角色】中导入，后续每镜头携带同一组参考图。
2. **逐镜头出首帧**：复制第三章每个镜头的 English Prompt 做【图片生成】，比例选 16:9（竖版选 9:16），2.39:1 留到剪映加黑边。变化类镜头（03/07/10）**首帧 + 尾帧各出一张**，走【首尾帧】图生视频；**镜头 11** **不用即梦**，直接导入 **`小红书_1` / `小红书_2` / `周报_1` / `周报_2`** 四张真机截图各 **2s**（16:9 工程）；缺素材时才用第三章「占位手机框」提示词补底。
3. **图生视频 + 运镜**：把首帧拖进【图生视频】，按下表填运镜与时长；6/8/10/14s 的镜头用"5s + 延长"或拆两段拼接。
4. **剪映合成**：即梦只出画面，**配乐（432Hz）/旁白/字幕/音效/统一调色**全部在剪映完成；**画外旁白统一温柔女声**（见第四章「旁白声线统一」）；台词镜头06（机器人开口）、镜头08（对话解困一问一答）、镜头09（孩子惊喜+机器人轻声）均可用即梦【对口型】。**字幕稿、镜头核对表、M11 的 SRT 草稿**等可在 Cursor 中按**第七章**提示词生成后粘贴到剪映。

### 各镜头即梦操作表

| 镜头 | 时长 | 即梦模式 | 图生视频运镜/动态描述（可直接填） |
|------|------|----------|--------------------------------|
| 01 | 6s | 文生图→图生视频 | 镜头缓缓推近书桌；男孩写字的手与肩部轻微自然动作；台灯光晕轻微闪烁 |
| 02 | 6s | 图生视频 | 轻微手持晃动；手停顿、指节收紧、橡皮擦动；草稿纸轻微抖动，营造不安 |
| 03 | 8s | **首尾帧**图生视频 | 首帧=左手腕安静手环；尾帧=左手腕上方悬浮全息数字 115 变红；镜头后拉并上摇，数字 98→107→115 跳动、波形越线转红 |
| 04 | 10s | **首尾帧**图生视频 + 文字贴图（**同镜两段式**，**不穿墙**） | **前段**：心率 115 瞬间，发光数据光线从孩子左手腕黑屏手环升起，镜头跟随光线上升；**后段**：转入客厅父母手机，光流接入点亮手机并轻微震动，**手机上方浮起半透明琥珀金全息气泡框**（先留空气泡，关怀文字**剪映贴图**），爸爸从旁凑近 |
| 05 | 14s | **首尾帧**图生视频 + 文字贴图（**同镜两段式**） | **前段**：沙发过肩特写，拇指在输入框逐字打字、光标闪烁、点击发送，爸爸关切探看（**App 文字建议剪映贴图**）；**发送后一道纤细丝滑曲线光线自手机升起，镜头跟随光线上升**；**后段**：光线汇入腾讯云中心光核，缓慢环绕推进，数据光点汇聚、两束指令光线分流射出 |
| 06 | 8s | 图生视频 + **对口型**（**承接05**） | **起幅一道纤细丝滑曲线光线自画面外飘入、汇入机器人**（承接05下发指令，**不出现腾讯云字样**）；缓慢推近机器人星形面屏（表情微笑闪烁），切孩子抬头；机器人先安抚再提议深呼吸，用对口型对上台词；环境仍偏冷、面屏柔光引入第一缕暖意 |
| 07 | 10s | **首尾帧**图生视频（拆 2 段） | 首帧=熄灭毛绒玩具/冷调，尾帧=琥珀暖光亮起/暖调；前段镜头后拉、光晕由内向外扩散、色温冷转暖，后段转极缓呼吸式推拉，光晕一胀一缩与男孩深呼吸同频、肩膀放松下沉 |
| 08 | 6s | 图生视频 + **对口型** | 机器人与孩子正反打对话；机器人询问"卡在哪一步"，孩子指着作业本说出困难，机器人引导一起拆解；用对口型对上一问一答的台词 |
| 09 | 6s | 图生视频 + **对口型** | 男孩眼睛一亮"哦——我明白了！"，开心地在划掉的算式旁流畅写下答案；机器人轻声鼓励；轻微推近至笔尖 |
| 10 | 8s | **首尾帧**图生视频 + 文字贴图 | 首帧=客厅沙发上父母手机里的红色心率峰值；尾帧=绿色平静曲线；镜头大幅后拉露出孩子书房与父母客厅沙发区的剖面两房间（**曲线/UI 建议剪映贴图**） |
| 11 | 8s | **剪映时间线（非即梦）** | **1920×1080**；顺序四段各 **2s 硬切**：`小红书_1` → `小红书_2` → `周报_1` → `周报_2`；按第二章镜头 11 表叠**功能字幕**；可选底=镜头 10 尾帧轻虚化；缺图时见第三章占位提示词 |

### 即梦提示词模板（图生视频可直接套）
```
[参考图：对应角色/道具定妆图] +
画面：<复制第三章该镜头 English Prompt 的 subject/background/details> ,
运镜：<上表运镜描述> ,
风格：photorealistic, live-action, real people, cinematic, natural skin texture ,
负向：anime, cartoon, illustration, 3D render, distorted hands, extra fingers, text artifacts
```

### 注意事项
- **文字/UI 别交给 AI**：手机推送、输入框、心率曲线等含文字的元素 AI 易出乱码，建议剪映/Figma 做贴图叠加。**镜头 11** 以**真机截屏**为画面主体；**功能卖点**仍建议用剪辑**外挂字幕条**（2s 一屏信息量大，字幕帮助扫读），勿依赖 AI 生成假界面。
- **概念镜头（04/05）**当 VFX 空镜单独生成光效，再在剪映合成。
- **手环静默不发光**：手环**全片黑屏、不发光**，戴在**左手腕**。提示词务必含 `smart wristband on left wrist, screen completely black, off, not glowing`，负向词加 `glowing wristband, screen with numbers, lit display`，否则模型爱自动给屏幕加数字或发光。
- **比例与黑边**：统一 16:9 出片，剪映加上下黑边得到 2.39:1；竖版另出 9:16。
- **调色统一**：导入剪映后做整体 LUT，前段冷青、镜头07 后转暖金（镜头06 机器人面屏柔光为冷暖过渡），保证 **11 段**风格连贯。
- **镜头 11**：**四张真机截图**各 **2s**，**16:9** 成片；**功能说明 = 外挂字幕条**（见第二章表）。可选底图 **10 尾帧轻虚化**；无截图时才用占位提示词出灰框底。

---

## 七、Cursor 辅助剪辑（说明 + 可复制提示词）

> **定位**：**Cursor 不是非编软件**，无法在 IDE 内完成与剪映 / Premiere / DaVinci 相同的时间线拖拽、关键帧、音频包络等操作。适合在 Cursor 中做的事包括：**镜头顺序与时长核对表**、**字幕 / 旁白文稿**、**SRT 时间轴草稿**、**导出与命名规范**、**ffmpeg 批处理拼接脚本**（同编码前提）、**检查清单**、**与 `DEMO_VIDEO_STORYBOARD.md` 对照的漏项提醒**等。  
> **建议工作流**：在 **剪映专业版 / Premiere / DaVinci** 中完成剪辑与导出；在 **Cursor** 中打开本仓库，**@ 引用** `docs/DEMO_VIDEO_STORYBOARD.md` 或粘贴下文提示词，让 AI 生成可粘贴到剪映的文本或脚本文件。

### 7.1 首次开剪 · 通用母提示词（复制到 Cursor 聊天框）

```
你是剪辑助理。请严格依据本仓库中的 @docs/DEMO_VIDEO_STORYBOARD.md 第二章「故事分镜表」与第六章「各镜头即梦操作表」：

1. 输出一份「剪映时间线核对表」：列 M01–M11（镜头 01–11）、建议顺序、第二章表格中的目标时长；若我随后提供「实际每段素材时长」，再帮我做一列「实际时长」与「与分镜差值」。
2. 列出 M01→M10 之间建议的转场方式（硬切 / 短叠化）及一句理由。
3. 镜头 11：按文档写清四张素材名（小红书_1 / 小红书_2 / 周报_1 / 周报_2）、各 2s、16:9、外挂字幕分屏文案（主标题 + 可选副标题）。
4. 不要编造文档里不存在的镜头编号或剧情。

（以下由你补充：工程分辨率 1920×1080 或 2.39:1；实际素材文件名与路径；是否含 M11。）
```

### 7.2 仅核对「我手里的素材时长」与分镜差异

```
我已按顺序有视频文件 M01…M10（可选 M11 为四张 PNG/JPG 静帧），实际时长如下（秒，请原样使用）：
M01: __  M02: __  M03: __  M04: __  M05: __  M06: __  M07: __  M08: __  M09: __  M10: __
（M11 若为静帧：四张各 2s，共 8s。）

请对照 @docs/DEMO_VIDEO_STORYBOARD.md 第二章各镜「时长」字段，用表格输出：镜号、分镜目标时长、我的实际时长、差值、剪辑建议（裁头尾 / 保持 / 是否需变速）。
```

### 7.3 生成镜头 11 外挂字幕 · SRT 草稿（2s 一卡，硬切）

```
请根据 @docs/DEMO_VIDEO_STORYBOARD.md 第二章「镜头 11」表格中的字幕方案，生成一份 **SubRip (.srt)** 草稿：
- 时间轴从 00:00:00,000 起；每段持续 **2 秒**；共 **4 条**字幕，对应顺序：小红书_1 → 小红书_2 → 周报_1 → 周报_2。
- 每条字幕正文两行：第一行主标题，第二行副标题（与文档一致）；SRT 规范换行。
- 若我给出 M11 在整条成片中的「起始时间码」（例如接在 M10 之后从 00:01:05,000 开始），请把整条时间轴平移到该起点。
```

### 7.4 生成旁白 / 台词「纯文本 + 大致镜位」（方便录音与对轨）

```
请从 @docs/DEMO_VIDEO_STORYBOARD.md 第二章提取所有「旁白·温柔女声」与「机器人台词」「孩子台词」及重要字幕句，按镜头顺序输出为 Markdown 列表：镜号、类型（旁白/对白/字幕）、正文。不要添加文档以外的台词。
```

### 7.5 导出与文件命名建议（让 Cursor 生成 README 片段）

```
请根据 @docs/DEMO_VIDEO_STORYBOARD.md，写一段「成片导出说明」Markdown，包含：
- 推荐分辨率与帧率（与素材一致）；
- M11 四张图命名约定与时长；
- 建议成品文件名：`温柔的信号_Master_16x9_YYYYMMDD.mp4`；
- 可选：纯叙事版（无 M11）与完整版（含 M11）两种命名后缀。
```

### 7.6 同编码视频无损拼接 · ffmpeg 提示词（可选，需本机已安装 ffmpeg）

```
我有多段 mp4，编码与分辨率一致，路径如下（每行一个绝对路径）：
（粘贴路径列表）

请生成一个 **安全的** bash 脚本：使用 ffmpeg concat demuxer（先 `file list.txt` 再 `-f concat -i list.txt -c copy out.mp4`），并写明：若编码不一致需先统一转码，不要用 re-encode 除非我确认。
```

### 7.7 使用注意

- 在 Cursor 中生成 **SRT / CSV / bash** 后，请**人工核对**时间码与帧率；AI 可能 off-by-one 帧。
- **音乐、响度、最终调色**仍在非编软件中完成；Cursor 输出仅作文案与结构辅助。
- 若项目中有实际素材目录，可在提示词中写明「所有路径相对于仓库根目录」，便于 Agent 写脚本。
