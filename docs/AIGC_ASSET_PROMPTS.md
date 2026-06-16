# 《温柔的信号》— AIGC 资产与道具提示词清单

> **对应分镜稿**：`docs/DEMO_VIDEO_STORYBOARD.md`。与本分镜配套的角色 / 表情 / 道具 / 场景一致性参考（文生图、图生视频定妆与合成）。
> **维护**：分镜变更后可用 `docs/META_PROMPTS_AI_VIDEO_PRODUCTION.md` **第二节**据此分镜再生成并 diff。

---

> 用途：用于 AIGC 生图 / 视频生成的**角色 / 场景 / 道具**一致性参考资产提示词。
> **全局硬性设定**：所有角色与道具定妆参考 **全程固定纯白色纯色背景（pure solid white background），不添加任何背景元素**。
> **风格统一**：真人实拍写实摄影风格（photorealistic / live-action，真人演员、自然皮肤质感），**非动画、非插画、非 3D 渲染**。
> **统一负向词（Negative）**：`anime, cartoon, illustration, 3D render, CGI, painting, plastic skin, doll-like, video game, extra fingers, distorted hands, text artifacts, background clutter, scenery, props in background`
> 本清单提示词**不含清晰度/质量词**（8K、超精细等），由模型自主选择。

---

## 一、角色画面提示词（按单人逐条拆分）

### 角色 01 — 朗朗（男孩 · 主角）

| 维度 | 细节 |
|------|------|
| 年龄特征 | 中国男孩，9–10 岁（小学三年级）；气质：活泼好动、精力旺盛、好奇心强，藏不住"坐不住"的劲头 |
| 外貌特征 | 圆脸、偏瘦小身材；深褐色大眼睛清澈灵动、眼神难以长时间聚焦带分散感；肤色暖黄健康；机灵好动、轻微躁动；儿童本色肌肤、无妆 |
| 发型细节 | 黑色整洁短发带少量刘海，发丝因不自觉抓挠略显蓬松凌乱，无发饰 |
| 服饰细节 | 浅米色/燕麦色圆领短袖纯棉 T 恤（领口略松垮）+ 深灰色休闲短裤（裤边随意）+ 短棉袜（袜口下滑至脚踝）或室内棉拖；左手腕简约智能手环（深灰表带、圆角屏幕，全程黑屏不发光静默无显示）；夏季居家休闲装，低饱和暖调 |

**基础定妆（中文）**：角色定妆，9–10 岁活泼好动的中国男孩，偏瘦小圆脸、深褐色大眼睛清澈灵动（带好动分散感）、蓬松凌乱黑色短发带少量刘海，浅燕麦色圆领短袖纯棉 T 恤（领口略松垮）、深灰色休闲短裤、下滑的短棉袜，左手腕戴简约智能手环（屏幕全黑、不发光、静默无显示），真人实拍写实摄影风格（真人儿童演员、自然皮肤质感，非动画非插画），柔和棚拍光，纯色纯白背景，无任何背景元素。

**基础定妆（EN）**：`character reference, a lively energetic 9-10-year-old Chinese boy, slim small build, round face, clear lively dark-brown eyes (active easily-distracted gaze), fluffy messy short black hair with a little fringe, oatmeal-beige crew-neck short-sleeve cotton T-shirt (slightly loose collar), dark gray casual shorts, short cotton socks slipped to ankles, a minimalist smart wristband on his LEFT wrist (dark-gray strap, rounded screen, screen completely black, off, not glowing, silent, no display), photorealistic live-action photography, real Chinese child actor, natural skin texture, not anime not illustration not 3D render, soft studio lighting, pure solid white background, no background elements`

### 角色 02 — 妈妈

| 维度 | 细节 |
|------|------|
| 年龄特征 | 约 35 岁中国女性；气质温柔知性、亲切治愈的成熟女性 |
| 外貌特征 | 鹅蛋脸、温和笑眼、身材匀称；自然皮肤质感、妆容柔和自然 |
| 发型细节 | 中长黑发自然披肩（或低马尾），无复杂发饰 |
| 服饰细节 | 暖驼色/燕麦色棉麻短袖上衣（或同色短袖连衣裙）+ 浅色七分/九分薄棉麻长裤；细巧耳钉；柔和低饱和，夏季居家温馨风 |

**基础定妆（中文）**：角色定妆，约 35 岁中国女性，温柔知性，鹅蛋脸温和笑眼，中长黑发自然披肩，暖驼色棉麻短袖上衣配浅色薄棉麻长裤，细巧耳钉，亲切治愈气质，真人实拍写实摄影风格（真人演员、自然皮肤质感，非动画非插画），柔和棚拍光线，纯色纯白背景，无任何背景元素。

**基础定妆（EN）**：`character reference, a 35-year-old Chinese woman, gentle and intellectual, oval face, warm smiling eyes, well-proportioned figure, medium-long black hair naturally draped over shoulders, warm camel/oat short-sleeve linen-cotton top, light-colored thin cropped linen trousers, delicate small ear studs, approachable healing aura, photorealistic live-action photography, real adult actress, natural skin texture, not anime not illustration not 3D render, soft studio lighting, pure solid white background, no background elements`

### 角色 03 — 爸爸

| 维度 | 细节 |
|------|------|
| 年龄特征 | 约 37 岁中国男性；气质沉稳内敛、可靠，家庭"定海神针" |
| 外貌特征 | 方正温和脸庞、身材偏高肩部略宽、眼神沉稳可靠、可带淡淡胡青；自然皮肤质感 |
| 发型细节 | 利落短黑发、干净利落，无发饰 |
| 服饰细节 | 深蓝色/藏青色圆领短袖 T 恤或短袖 Polo 衫 + 深色薄棉休闲短裤或薄长裤；无多余配饰，简洁清爽 |

**基础定妆（中文）**：角色定妆，约 37 岁中国男性，肩部略宽、利落短黑发，方正温和的脸带淡淡胡青，藏青色圆领短袖 T 恤与深色薄休闲短裤，眼神沉稳可靠，真人实拍写实摄影风格（真人演员、自然皮肤质感，非动画非插画），柔和棚拍光线，纯色纯白背景，无任何背景元素。

**基础定妆（EN）**：`character reference, a 37-year-old Chinese man, slightly broad shoulders, taller build, neat short black hair, square gentle face with light stubble, calm reliable gaze, navy crew-neck short-sleeve T-shirt, dark thin casual shorts, no extra accessories, clean and simple, photorealistic live-action photography, real adult actor, natural skin texture, not anime not illustration not 3D render, soft studio lighting, pure solid white background, no background elements`

---

## 二、角色多表情独立定妆提示词（表情包 / Expression Sheet）

> 用法：锁定上方"基础定妆"的 seed / 参考图后，分别套用以下每条表情提示词，逐张生成统一参考图的表情包。
> 表情依据剧本情绪弧线提取，**仅描述面部表情（眉眼、神情、嘴部），不含手部及其他肢体动作**，纯白背景、无背景元素。

### 朗朗 — 表情包（6 表情，仅面部）

**E1 · 好动专注**
- 中文：朗朗的好动专注神情，眉头微聚、眼神短暂高度投入但仍带一丝坐不住的灵动分散感，嘴唇微抿。
- EN：`[boy base look] facial expression only: playful focus, brows lightly drawn, eyes briefly intensely engaged yet still lively and a bit restless, lips slightly pressed, head-and-shoulders portrait, pure solid white background, no background elements`

**E2 · 分心走神**
- 中文：朗朗分心走神的神情，眼神飘离、目光涣散不聚焦，嘴角微张，一副心不在焉的样子。
- EN：`[boy base look] facial expression only: distracted and absent-minded, gaze drifting and unfocused, mouth slightly open, inattentive look, head-and-shoulders portrait, pure solid white background, no background elements`

**E3 · 急躁焦虑**
- 中文：朗朗急躁焦虑的神情，眉头紧锁、抿嘴、眼神紧绷无助。
- EN：`[boy base look] facial expression only: impatient and anxious, brows tightly furrowed, lips pressed, tense helpless eyes, head-and-shoulders portrait, pure solid white background, no background elements`

**E4 · 抬头好奇**
- 中文：朗朗好奇的神情，眼神从紧绷转为好奇明亮，眼睛睁大，注意力被吸引。
- EN：`[boy base look] facial expression only: curious look, gaze shifting from tense to bright and curious, eyes widened, attention drawn, head-and-shoulders portrait, pure solid white background, no background elements`

**E5 · 闭眼深呼吸（放松）**
- 中文：朗朗闭眼深呼吸的神情，眼睛轻闭、眉头舒展、表情松动平静，焦虑逐渐平复。
- EN：`[boy base look] facial expression only: eyes gently closed taking a deep breath, brows relaxed, face softening and calm, anxiety easing, head-and-shoulders portrait, pure solid white background, no background elements`

**E6 · 放松咧嘴笑（释然）**
- 中文：朗朗释然放松的咧嘴笑，嘴角上扬、眼睛弯起、神情舒展自信、轻松愉悦。
- EN：`[boy base look] facial expression only: relieved relaxed grin, corners of mouth up, eyes curved, open confident and happy look, head-and-shoulders portrait, pure solid white background, no background elements`

### 妈妈 — 表情包（3 表情，仅面部）

**E1 · 关切克制**
- 中文：妈妈关切而克制的神情，眉眼带轻微担忧但不慌乱，目光专注，沉稳冷静。
- EN：`[mom base look] facial expression only: concerned yet composed, slight worry in the eyes but no panic, focused gaze, calm and steady, head-and-shoulders portrait, pure solid white background, no background elements`

**E2 · 专注认真**
- 中文：妈妈专注认真的神情，眼神专注沉静、眉眼平和而投入。
- EN：`[mom base look] facial expression only: focused and serious, attentive calm gaze, peaceful engaged look, head-and-shoulders portrait, pure solid white background, no background elements`

**E3 · 欣慰柔和微笑**
- 中文：妈妈欣慰柔和的微笑，温和笑眼、嘴角轻扬，治愈安心的神情。
- EN：`[mom base look] facial expression only: relieved gentle smile, warm smiling eyes, soft upturned lips, healing and reassured, head-and-shoulders portrait, pure solid white background, no background elements`

### 爸爸 — 表情包（3 表情，仅面部）

**E1 · 专注关切**
- 中文：爸爸专注关切的神情，眼神专注沉稳、略带关切，眉头微聚。
- EN：`[dad base look] facial expression only: focused and concerned, attentive steady gaze with slight concern, brows lightly drawn, head-and-shoulders portrait, pure solid white background, no background elements`

**E2 · 坚定支持**
- 中文：爸爸坚定支持的神情，目光坚定可靠、眼神沉稳，传递安定的支撑感。
- EN：`[dad base look] facial expression only: firm and supportive, steady reliable gaze, calm assuring eyes, head-and-shoulders portrait, pure solid white background, no background elements`

**E3 · 安心浅笑**
- 中文：爸爸安心的浅笑，神情放松、嘴角微扬，沉稳中透出温暖。
- EN：`[dad base look] facial expression only: relieved faint smile, relaxed look, slightly upturned lips, warmth within calmness, head-and-shoulders portrait, pure solid white background, no background elements`

---

## 三、道具画面提示词

> 纯白色纯色背景，仅呈现道具本体，不添加任何背景元素。

**P1 · 智能手环（核心叙事道具）**
- 细节：简约风格、圆角屏幕、深灰表带；**全程黑屏、不发光、静默无显示**（屏幕纯黑、无任何数字与亮光）
- EN：`a minimalist smart wristband, dark-gray strap, rounded screen, screen completely black, off, not glowing, silent, no display, no numbers, photorealistic real product, pure solid white background, no background elements`
- Negative：`glowing wristband, screen with numbers, lit display`

**P2 · 毛绒玩具 Glow（桌面陪伴）**
- 细节：圆润柔软可爱的毛绒玩具，毛绒纤维质感，内置灯光与音响；可亮起治愈琥珀色暖光（自内而外发光、光晕晕染），未亮时为安静熄灭状态
- 备注：已有实物，**以上传实拍图为准**
- EN：`a round soft cute plush companion toy, fuzzy fiber texture, built-in light and speaker, can glow with healing amber warm light from within, photorealistic real product, pure solid white background, no background elements`

**P3 · 星星机器人 Star（桌面交互机器人）**
- 细节：星形面屏陪伴交互机器人，圆润外壳有高光，可爱科技产品实物质感；星形面屏可亮起柔光眼神与微笑像素表情
- 备注：已有实物，**以上传实拍图为准**
- EN：`a cute star-faced companion desk robot, rounded glossy shell, real tech product texture, star-shaped face screen showing soft glowing eyes and a smiling pixel expression, photorealistic real product, pure solid white background, no background elements`

**P4 · 父母手机（智能手机）**
- 细节：智能手机；剧情中由坐在客厅沙发上的父母使用；可亮屏弹出关怀推送横幅、可震动；App 含文本输入框、软键盘、闪烁光标、发送按钮；可显示心率曲线（红色高峰回落至绿色平静区间）
- 备注：含文字的 UI 元素建议后期贴图（AI 易出乱码）
- **状态 A · 推送震动**（镜头 05）
  - EN：`a modern black-frame smartphone, glossy glass front, screen ON showing a notification banner at the top, phone is slightly off-level hinting vibration, soft warm living-room light reflected on the glass surface, photorealistic real product photography, soft diffused studio lighting, subtle drop shadow, pure solid white background, no background elements`
  - Negative：`glowing wristband, cartoon UI, 3D render, plastic-looking`
- **状态 B · 输入框 + 软键盘**（镜头 06）
  - EN：`a modern smartphone screen close-up, an app feedback form with a text input field, a full on-screen keyboard visible, a blinking text cursor in the input box, a highlighted send button, screen glow illuminating the surroundings, photorealistic real product photography, soft diffused lighting, pure solid white background, no background elements`
  - Negative：`Chinese characters on screen, distorted UI text, 3D render`
- **状态 C · 心率曲线平复**（镜头 12）
  - EN：`a modern smartphone screen displaying a heart-rate graph, the curve descending from a red peak into a calm green flat zone, a health app interface with a reassuring calm status indicator, warm ambient glow, photorealistic real product photography, pure solid white background, no background elements`
  - Negative：`animated screen, 3D render, text artifacts`

**P5 · 书桌文具组**（书房道具，按单品独立生成）
- **P5-a · 铅笔**
  - EN：`a single wooden pencil with a slightly worn graphite tip and visible grip marks from use, warm soft studio lighting, macro shot, photorealistic real product photography, subtle drop shadow, pure solid white background, no background elements`
- **P5-b · 草稿纸**
  - EN：`a white draft paper with handwritten math equations, some crossed out with eraser marks, slight wrinkles and pencil indentations, overhead flat lay, photorealistic, pure solid white background, no background elements`
- **P5-c · 橡皮**
  - EN：`a rectangular white rubber eraser with worn edges and scattered rubber crumbs around it, soft studio lighting, macro shot, photorealistic real product photography, pure solid white background, no background elements`
- **P5-d · 书桌暖黄台灯**（书房唯一光源）
  - EN：`a small warm-yellow desk lamp with a round shade, soft warm amber glow illuminating from the lampshade, photorealistic real product photography, the lamp emitting gentle warm light, soft diffused studio lighting, pure solid white background, no background elements`
  - Negative：`harsh light, neon, cold light, 3D render`

**P6 · 客厅沙发**（客厅背景道具，镜头 05/06/12）
- 细节：简洁现代风布艺沙发，暖驼色，与角色服装色调协调；无多余花纹；剧情中父母并肩坐在此沙发上查看手机，作为温馨客厅的背景主体
- EN：`a modern simple fabric sofa in warm camel or oatmeal beige, clean minimal design, soft natural texture, slightly wrinkled cushions suggesting everyday home use, photorealistic real product photography, soft diffused studio lighting, subtle drop shadow, pure solid white background, no background elements`
- Negative：`patterned fabric, ornate, 3D render, CGI, cartoon`

---

## 四、场景画面提示词（仅提取文本明确提及的场景核心元素）

> 忠实提取场景核心元素与描述词，不脑补文本外信息。

**S1 · 夜晚书房（孩子端，镜头 01/02/08/09/10/11）**
- 核心元素：书桌、暖黄台灯（唯一光源）、书架、窗帘、墙面儿童画与课程表
- 描述词：夜晚温馨书房、暖黄台灯柔光、背景虚化成温柔光斑、浅景深

**S2 · 书桌台面（特写场景，镜头 02）**
- 核心元素：书桌台面、草稿纸、作业本
- 描述词：同一书桌台面、青灰冷调、对比加强营造压迫感

**S3 · 父母端温暖客厅（镜头 05/06）**
- 核心元素：客厅沙发、父母并肩坐在沙发上、父母手机
- 描述词：温暖客厅沙发区、客厅暖光、父母坐在沙发上查看手机、浅景深

**S4 · 腾讯云数字空间（概念可视化，镜头 07）**
- 核心元素：中央发光光球（光核）、漂浮数据节点与网格、两条分流光线/光束、隐现"腾讯云 / Tencent Cloud"字样
- 描述词：深蓝色抽象数据宇宙、对称放射式构图、深蓝冷底＋金色暖光点、科技辉光

**S5 · 剖面式两房间（信号穿墙 / 收尾全景，镜头 04/12）**
- 核心元素：剖面建筑结构、一侧儿童书房、一侧温馨客厅沙发区、父母并肩坐在沙发上、半透明化墙体
- 描述词：剖面式两房间同框，孩子在书房写作业，父母坐在客厅沙发上查看手机，一束光流横贯/两房同沐一片暖光、2.39:1 宽银幕

---

## 五、使用建议

1. **先锁基础定妆**：用第一节"基础定妆"各生成一张朗朗/妈妈/爸爸参考图，锁定 seed 或导入参考图。
2. **再出表情包**：携带同一参考图，逐条套用第二节表情提示词，得到统一的表情参考集。
3. **道具一致性**：智能手环由 AI 生成并锁形（务必保持黑屏不发光、戴左手腕）；毛绒玩具 Glow、星星机器人 Star 以上传实拍图为准。
4. **场景**：S1–S5 用于分镜出图时的场景元素引用；本清单的角色/道具资产统一纯白背景，便于后续合成与抠像。
5. **含文字 UI**（手机推送、输入框、心率曲线）建议剪映/Figma 贴图，避免 AI 乱码。