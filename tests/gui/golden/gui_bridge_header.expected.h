#ifndef GUI_BRIDGE_GENERATED_H
#define GUI_BRIDGE_GENERATED_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { GUI_BRIDGE_ABI_VERSION = 5u };

typedef enum GUIBridgeActionTag {
  GUI_BRIDGE_ACTION_INCREMENT = 0,
  GUI_BRIDGE_ACTION_REFRESH = 1,
  GUI_BRIDGE_ACTION_SYNC = 2
} GUIBridgeActionTag;

typedef struct GUIBridgeBuffer {
  uint8_t* data;
  uint32_t len;
} GUIBridgeBuffer;

typedef struct GUIBridgeDispatchOutput {
  GUIBridgeBuffer statePatch;
  GUIBridgeBuffer effects;
  GUIBridgeBuffer emittedActions;
  GUIBridgeBuffer diagnostics;
} GUIBridgeDispatchOutput;

typedef void* (*GUIBridgeAllocFn)(size_t size);
typedef void (*GUIBridgeFreeFn)(void* ptr);
typedef int32_t (*GUIBridgeDispatchFn)(const uint8_t* payload, uint32_t payloadLen, GUIBridgeDispatchOutput* out);
typedef int32_t (*GUIBridgeGetNotifyFdFn)(void);
typedef int32_t (*GUIBridgeWaitShutdownFn)(int32_t timeoutMs);

typedef struct GUIBridgeFunctionTable {
  uint32_t abiVersion;
  GUIBridgeAllocFn alloc;
  GUIBridgeFreeFn free;
  GUIBridgeDispatchFn dispatch;
  GUIBridgeGetNotifyFdFn getNotifyFd;
  GUIBridgeWaitShutdownFn waitShutdown;
} GUIBridgeFunctionTable;

const GUIBridgeFunctionTable* gui_bridge_get_table(void);

#ifdef __cplusplus
}
#endif

#endif
