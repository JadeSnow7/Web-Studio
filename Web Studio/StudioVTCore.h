#ifndef WEB_STUDIO_VT_CORE_H
#define WEB_STUDIO_VT_CORE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#if defined(WEB_STUDIO_VT)
#include <ghostty/vt.h>
#include <ghostty/vt/key/event.h>

typedef struct StudioVT StudioVT;
typedef void (*StudioVTReplyFn)(const uint8_t *bytes, size_t len, void *userdata);

typedef struct {
  size_t size;
  bool has_foreground;
  bool has_background;
  bool has_cursor;
  bool has_palette;
  GhosttyColorRgb foreground, background, cursor;
  GhosttyColorRgb palette[256];
} StudioVTTheme;

typedef struct {
  size_t size;
  size_t text_offset;
  size_t text_len;
  GhosttyCellWide wide;
  GhosttyColorRgb foreground, background, underline;
  bool has_foreground, has_background, has_underline, selected;
  GhosttyStyle style;
} StudioVTCell;

typedef struct {
  size_t size;
  uint16_t cols, rows;
  size_t cell_count;
  StudioVTCell *cells;
  uint8_t *text;
  size_t text_len;
  GhosttyRenderStateCursor cursor;
  GhosttyRenderStateColors colors;
  GhosttyTerminalScrollbar scrollbar;
  uint8_t *viewport_text;
  size_t viewport_text_len;
  bool viewport_text_truncated;
} StudioVTSnapshot;

typedef struct {
  size_t size;
  GhosttyKey key;
  GhosttyKeyAction action;
  GhosttyMods mods;
  const char *utf8;
  size_t utf8_len;
  uint32_t unshifted_codepoint;
} StudioVTKey;

StudioVT *studio_vt_create(uint16_t cols, uint16_t rows, uint32_t cell_width_px, uint32_t cell_height_px,
                           StudioVTReplyFn reply, void *userdata);
void studio_vt_free(StudioVT *ctx);
void studio_vt_feed(StudioVT *ctx, const uint8_t *bytes, size_t len);
GhosttyResult studio_vt_resize(StudioVT *ctx, uint16_t cols, uint16_t rows, uint32_t cell_width_px, uint32_t cell_height_px);
GhosttyResult studio_vt_set_theme(StudioVT *ctx, const StudioVTTheme *theme);
GhosttyResult studio_vt_snapshot(StudioVT *ctx, StudioVTSnapshot *out);
void studio_vt_snapshot_free(StudioVTSnapshot *snapshot);
GhosttyResult studio_vt_encode_key(StudioVT *ctx, const StudioVTKey *key, uint8_t **out_bytes, size_t *out_len);
void studio_vt_bytes_free(void *bytes);

void studio_vt_scroll_delta(StudioVT *ctx, intptr_t delta);
void studio_vt_scroll_to(StudioVT *ctx, size_t row);
void studio_vt_scroll_bottom(StudioVT *ctx);
GhosttyResult studio_vt_select_drag(StudioVT *ctx, uint16_t start_col, uint16_t start_row,
                                     uint16_t end_col, uint16_t end_row, int behavior);
GhosttyResult studio_vt_selection_begin(StudioVT *ctx, uint16_t col, uint16_t row, int click_count);
GhosttyResult studio_vt_selection_update(StudioVT *ctx, uint16_t col, uint16_t row);
GhosttyResult studio_vt_selection_end(StudioVT *ctx);
GhosttyResult studio_vt_select_word(StudioVT *ctx, uint16_t col, uint16_t row);
GhosttyResult studio_vt_select_line(StudioVT *ctx, uint16_t col, uint16_t row);
GhosttyResult studio_vt_select_all(StudioVT *ctx);
GhosttyResult studio_vt_clear_selection(StudioVT *ctx);
GhosttyResult studio_vt_selected_text(StudioVT *ctx, uint8_t **out_bytes, size_t *out_len);
GhosttyResult studio_vt_paste(StudioVT *ctx, const uint8_t *bytes, size_t len, bool allow_unsafe,
                              bool *out_written);
GhosttyResult studio_vt_focus(StudioVT *ctx, bool focused, uint8_t **out_bytes, size_t *out_len);
GhosttyResult studio_vt_mouse(StudioVT *ctx, int action, int button, uint32_t modifiers,
                              double x_pixels, double y_pixels, uint32_t screen_width,
                              uint32_t screen_height, uint32_t cell_width, uint32_t cell_height,
                              uint32_t padding_top, uint32_t padding_bottom,
                              uint32_t padding_left, uint32_t padding_right,
                              uint8_t **out_bytes, size_t *out_len);
bool studio_vt_mouse_reporting(StudioVT *ctx);
GhosttyResult studio_vt_pwd(StudioVT *ctx, uint8_t **out_bytes, size_t *out_len);

#endif
#endif
