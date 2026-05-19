#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 启动长轮询任务，等 WiFi 拿到 IP 后开始连云端拉指令。 */
void Cloud_Start(void);

/** 返回上次成功收到云端响应（含空响应）的时间戳，毫秒 since boot。0 表示从未成功。 */
unsigned long Cloud_LastSuccessMs(void);

#ifdef __cplusplus
}
#endif
