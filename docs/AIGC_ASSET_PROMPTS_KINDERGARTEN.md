# AI 大赛演示片（幼儿园教师模式）— AIGC 资产与道具提示词清单

> **对应分镜稿**：`docs/DEMO_VIDEO_STORYBOARD_KINDERGARTEN.md`  
> **用途**：文生图 / 图生视频前的**人物锁定、手环颜色码、教室与手工道具**一致性参考。  
> **维护**：分镜迭代后可用 `docs/META_PROMPTS_AI_VIDEO_PRODUCTION.md` **第二节**据分镜再生成本文件并人工校对。

> **全局硬性设定（定妆与道具单品图）**：角色与**手环 / 积木等道具单品**的定妆参考图建议使用 **pure solid white background**，无杂物，便于抠像；**全景教室镜头**出图时使用分镜「分镜统一风格锚点」中的自然窗光，勿与定妆白底混淆。  
> **风格统一**：真人实拍、温情纪实 + 轻微纪录片感（photorealistic / live-action / cinematic documentary warmth），自然肤质与织物纹理，**非动画、非插画、非 3D 渲染**；儿童表情克制真实。  
> **统一负向词（Negative）**：`anime, cartoon, illustration, 3D render, CGI, painting, plastic skin, doll-like, video game, extra fingers, distorted hands, text artifacts, crying exaggerated face, neon oversaturation, whole-frame color wash`  
> 本清单**不含** 8K / masterpiece 等质量堆砌。

---

## 一、角色画面提示词（按人物逐条）

### 角色 01 — 刘老师（幼儿园特教老师）

| 维度 | 细节 |
|------|------|
| 年龄气质 | 典型中国女性，约 27–32 岁；亲切、专业、行动力强；温柔敏锐 |
| 外貌 | 黑或深棕发，**低马尾或丸子头（二选一全片固定）**；年轻温和面庞；深褐眼，专注温柔；自然偏暖肤色 |
| 服饰 | **浅蓝或浅绿**棉质 polo / 工作衬衫略宽松；**深色直筒长裤**；浅色软底平底鞋；胸前可有**极小园徽**（约 1.5cm） |
| 手环 | **左手腕**：**深灰或黑色宽表带**、**方形表盘**，表盘略大于学童款，全片固定 |

**基础定妆（中文）**：角色定妆，典型中国女性幼儿园教师约 29 岁，黑色低马尾，年轻温和无细纹，浅蓝色幼儿园 polo 衫、深色直筒长裤、浅色平底鞋，左手腕深灰宽表带智能方表盘手环，目光温柔专注，真人实拍写实，柔和棚拍光，纯色纯白背景，无任何背景元素。

**基础定妆（EN）**：`character reference, Chinese female kindergarten teacher Ms. Liu, approximately 28-30 years old, neat black low ponytail, youthful gentle face, light-blue polo-style work shirt, dark straight trousers, light soft-sole flat shoes, slim smart band on LEFT wrist, dark gray wide strap, slightly larger square watch dial, warm attentive expression, photorealistic live-action, soft studio lighting, pure solid white background, no background elements`

### 角色 02 — 杜同学（蓝色手环）

| 维度 | 细节 |
|------|------|
| 年龄气质 | 典型中国男童 4–5 岁，大班；圆润略矮小，内敛，偶有迷茫 |
| 外貌 | 黑色短发略软塌；暖白偏粉肤色；大眼睛长睫毛；唇略厚，静默时微张 |
| 服饰 | **浅黄圆领 T 恤印小鸭子**；**牛仔背带裤**；**白色运动鞋** |
| 手环 | **左手腕**，**蓝色宽表带**，表盘略大；报警时边缘可发**蓝色光晕**（以分镜为准） |

**基础定妆（中文）**：角色定妆，4–5 岁中国男童杜同学，黑色短软发，暖白偏粉肤色大眼睛，浅黄小鸭 T 恤、牛仔背带裤、白运动鞋，左手腕蓝色宽表带手环，真人实拍，柔和棚拍光，纯色纯白背景，无任何背景元素。

**基础定妆（EN）**：`character reference, Chinese kindergartner boy Student Du, 4-5 years old, soft short black hair, warm peachy skin, large dark eyes, pale yellow T-shirt with small duck print, denim overalls, white sneakers, smart band on LEFT wrist with BLUE wide strap, photorealistic live-action, soft studio lighting, pure solid white background, no background elements`

### 角色 03 — 陈同学（橙色手环）

| 维度 | 细节 |
|------|------|
| 年龄气质 | 典型中国男童 5–6 岁；标准偏活泼，略高略瘦于杜同学 |
| 外貌 | 黑色短发较整齐；健康暖黄肤色；圆眼双眼皮；嘴角常微垂，低落但不哭 |
| 服饰 | **白 T 恤印小火车**；**藏青运动短裤**；**灰色运动鞋** |
| 手环 | **左手腕**，**橙色宽表带**；报警时**橙色光晕** |

**基础定妆（中文）**：角色定妆，5–6 岁中国男童陈同学，黑色短发略整齐，暖黄肤色圆眼，白色小火车 T 恤、藏青运动短裤、灰运动鞋，左手腕橙色宽表带手环，真人实拍，柔和棚拍光，纯色纯白背景，无任何背景元素。

**基础定妆（EN）**：`character reference, Chinese kindergartner boy Student Chen, 5-6 years old, neat short black hair, warm skin, round double-eyelid eyes, white T-shirt with small train print, dark navy shorts, gray sneakers, smart band on LEFT wrist with ORANGE wide strap, photorealistic live-action, soft studio lighting, pure solid white background, no background elements`

### 角色 04 — 林同学（绿色手环）

| 维度 | 细节 |
|------|------|
| 年龄气质 | 典型中国女童 4–5 岁；圆润娇小，三名学童中个头最小 |
| 外貌 | 黑发**两侧小揪揪**全片固定；嫩白偏粉肤；不适时抿嘴或低头 |
| 服饰 | **粉色碎花连衣裙**及膝；**粉白玛丽珍鞋**；可小白袜 |
| 手环 | **左手腕**，**绿色宽表带**；报警时**绿色光晕** |

**基础定妆（中文）**：角色定妆，4–5 岁中国女童林同学，黑色两侧小揪揪，嫩白偏粉肤色，粉色碎花连衣裙、粉白玛丽珍鞋与小白袜，左手腕绿色宽表带手环，真人实拍，柔和棚拍光，纯色纯白背景，无任何背景元素。

**基础定妆（EN）**：`character reference, Chinese kindergartner girl Student Lin, 4-5 years old, black hair in two small buns on sides, fair peachy skin, pink floral dress to knee, pink-white mary jane shoes, white ankle socks, smart band on LEFT wrist with GREEN wide strap, photorealistic live-action, soft studio lighting, pure solid white background, no background elements`

### 角色 05 — 杨同学（路过，T04 虚焦）

| 维度 | 细节 |
|------|------|
| 说明 | 全片**仅此一镜**；典型中国男童；**无定妆细表**，以背影 / 模糊侧脸为主，勿与杜、陈混淆 |

**基础定妆（EN）**：`character reference, young Chinese kindergartner boy blurred silhouette or back view only, generic school clothes, out of focus, photorealistic, pure solid white background OR shallow dof classroom plate — use only for T04 crowd dispute plate`

---

## 二、角色多表情独立定妆（仅面部 / Expression）

> 锁定 §一「基础定妆」seed 或参考图后逐条生成；**仅描述眉眼嘴神情**；纯白背景。

### 刘老师 — 表情包

**E1 · 温和巡视**  
- EN：`[Ms Wang base] facial expression only: gentle scanning smile, calm attentive eyes, soft closed-lip smile, head-and-shoulders portrait, pure solid white background`

**E2 · 收到手环提示（微蹙即松）**  
- EN：`[Ms Wang base] facial expression only: subtle micro-frown then release, eyes flick toward wrist then back, composed professional calm, head-and-shoulders portrait, pure solid white background`

**E3 · 蹲下调解时的专注**  
- EN：`[Ms Wang base] facial expression only: crouching-level neutral warm gaze, non-judgmental steady eyes, lips softly parted for slow speech, head-and-shoulders portrait, pure solid white background`

**E4 · 安抚后的柔和**  
- EN：`[Ms Wang base] facial expression only: relieved soft upturned lip corners, warm eyes meeting child, head-and-shoulders portrait, pure solid white background`

### 杜同学 — 表情包

**E1 · 安静专注手工**  
- EN：`[Du base] facial expression only: quiet focused downward gaze, neutral mouth, calm, head-and-shoulders portrait, pure solid white background`

**E2 · 感官不适（捂耳倾向）**  
- EN：`[Du base] facial expression only: mild discomfort, slightly vacant eyes, lips slightly parted, subtle distress no crying, head-and-shoulders portrait, pure solid white background`

### 陈同学 — 表情包

**E1 · 低落发呆**  
- EN：`[Chen base] facial expression only: subdued gaze, corners of mouth slightly down, distant eyes, head-and-shoulders portrait, pure solid white background`

**E2 · 紧张加剧（未哭）**  
- EN：`[Chen base] facial expression only: shallow knit brows, unfocused eyes, tight lips, restrained anxiety no tears, head-and-shoulders portrait, pure solid white background`

**E3 · 放松被看见**  
- EN：`[Chen base] facial expression only: brows easing, eyes softening toward teacher, slight lip part breathing deeper, head-and-shoulders portrait, pure solid white background`

### 林同学 — 表情包

**E1 · 低头玩纸角**  
- EN：`[Lin base] facial expression only: eyes down, mild withdrawal, lips gently pressed, head-and-shoulders portrait, pure solid white background`

**E2 · 蜷缩紧张**  
- EN：`[Lin base] facial expression only: subtle tension, downcast eyes, small pout, no crying, head-and-shoulders portrait, pure solid white background`

---

## 三、道具画面提示词（P 系列）

> 单品图：**纯白底**；屏上中文 / HUD 数字建议后期贴图。

**P1 · 学童手环 — 杜同学（蓝）**  
- 细节：宽蓝表带、略大表盘；**平静**：极低常亮约 20% 蓝光；**报警**（T02）：边缘光晕渐亮、半透橙系 HUD 数字（分镜示例 82→108）— **数字建议后期**  
- EN（平静）：`blue wide-strap children's smart band on white background, very dim blue rim glow about 20 percent, photorealistic product, pure solid white background`  
- Negative：`wrong strap color, orange strap, green strap`

**P2 · 学童手环 — 陈同学（橙）**  
- EN（平静）：`orange wide-strap children's smart band, very dim orange rim glow low brightness, photorealistic product, pure solid white background`  
- EN（报警加强）：`orange wide-strap children's smart band, edge glow intensifying to mid brightness, subtle pulse ring on bezel, semi-transparent HUD area blank for post text, photorealistic, pure solid white background`  
- Negative：`blue strap, green strap, neon cyberpunk`

**P3 · 学童手环 — 林同学（绿）**  
- EN：`green wide-strap children's smart band, very dim green rim glow, photorealistic product, pure solid white background`  
- Negative：`blue strap, orange strap`

**P4 · 刘老师手环（深灰方表盘）**  
- **状态 A · 日常**（T01/T06）：深灰表带、方形表盘，低调常亮  
- **状态 B · 静默提示陈同学**（T03）：表盘侧面**橙色脉冲**一圈；屏内「陈同学·108」等**建议后期贴字**  
- EN（B）：`dark gray wide-strap adult smart band with square face, subtle orange pulse glow on bezel edge, screen area dark with no readable fake text, photorealistic, pure solid white background`  
- Negative：`round watch dial, child-sized band on teacher, wrong pulse color for wrong student`

**P5 · 手工材料组**（T01/T02/T06）  
- EN：`kindergarten paper craft supplies on white: colored paper sheets, child-safe scissors, glue stick, pencil with slight wear, scattered paper bits, overhead flat lay, photorealistic, pure solid white background`

**P6 · 红色积木（争执核心道具，T04/T05）**  
- EN：`a single red wooden building block, matte paint, slight edge wear, macro product shot, photorealistic, pure solid white background`

**P7 · 小木椅 + 彩色积木筐（T04）**  
- EN：`small wooden preschool chair with a woven basket of colorful wooden blocks on the seat, photorealistic product staging, soft studio light, pure solid white background`

**P8 · 小圆桌（教室）**  
- EN：`small round kindergarten table, light wood or laminate, clean minimal, photorealistic, pure solid white background`

---

## 四、场景画面提示词（仅分镜已写元素）

> 忠实提取，不脑补陈设。

**S1 · 明亮幼儿园教室（T01 / T06 等）**  
- 核心：上午自然窗光（约 4800–5500K）自一侧斜入；**三张小圆桌**；手工拼贴（彩纸、剪刀、胶棒）；墙面**彩色挂图与幼儿作品**（可虚化）；**玩具收纳架**、一株绿植；浅景深、中低对比、极轻颗粒（见分镜「风格锚点」）  
- 涉及：**T01** 建立；**T06** 对比角；背景可虚焦刘老师与陈同学

**S2 · 陈同学小桌特写区（T02 / T04 / T05）**  
- 核心：彩纸散落、铅笔、桌面材料连续；T02 曝光略压；T05 桌角**红色积木已轻放**、景深最浅  
- 涉及：**T02** 情绪波动；**T04** 争执与调解；**T05** 安抚高点

**S3 · 教室中景走动线（T04 节拍①）**  
- 核心：刘老师轻步入画、跟焦跟拍、背景流动虚焦  
- 涉及：**T04-①**

**S4 · 落版抽象底（T08）**  
- 核心：深褐或黑底渐变；中央主副标题位；可选三枚**蓝/橙/绿**色点识别；无真人或极短叠化  
- 涉及：**T08**

---

## 五、使用建议

1. **颜色码铁律**：蓝 = 杜同学，橙 = 陈同学，绿 = 林同学，深灰/黑方表盘 = 刘老师；生成前一次性定案，跨镜不得串色。  
2. **流程**：先按 §一各出定妆参考图并锁 seed；再出 §二表情；道具 P1–P8 锁形；分镜出图时在每条 prompt 首行粘贴分镜稿内「人物锁定」原文。  
3. **HUD / 中文屏显**：一律后期贴图，避免 AI 乱码。  
4. **与实机差异**：答辩口径见 `DEMO_VIDEO_STORYBOARD_KINDERGARTEN.md` 文末「成片与实机」表。
