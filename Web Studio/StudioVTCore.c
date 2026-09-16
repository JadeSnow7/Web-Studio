#include "StudioVTCore.h"

#if defined(WEB_STUDIO_VT)
#include <ghostty/vt.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/selection.h>
#include <ghostty/vt/paste.h>
#include <ghostty/vt/focus.h>
#include <ghostty/vt/mouse.h>
#include <stdlib.h>
#include <string.h>

struct StudioVT {
  GhosttyTerminal terminal;
  GhosttyRenderState render;
  GhosttyKeyEncoder encoder;
  GhosttyKeyEvent event;
  StudioVTReplyFn reply;
  void *userdata;
  GhosttyTerminalWritePtyFn write_callback;
  uint8_t *reply_bytes;
  size_t reply_len;
  size_t reply_cap;
  uint32_t cell_width_px, cell_height_px;
  const uint8_t *paste_bytes;
  size_t paste_len;
  GhosttyMouseEncoder mouse_encoder;
  GhosttyMouseEvent mouse_event;
  uint32_t mouse_button_mask;
  GhosttySelectionGesture selection_gesture;
  bool selection_active;
};

static void studio_vt_write(GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t data_len) {
  (void)terminal;
  StudioVT *ctx = (StudioVT *)userdata;
  if (!ctx || !data) return;
  uint8_t *copy = (uint8_t *)realloc(ctx->reply_bytes, data_len ? data_len : 1);
  if (!copy) return;
  ctx->reply_bytes = copy;
  ctx->reply_cap = data_len;
  ctx->reply_len = data_len;
  memcpy(ctx->reply_bytes, data, data_len);
  if (ctx->reply) ctx->reply(ctx->reply_bytes, ctx->reply_len, ctx->userdata);
}

StudioVT *studio_vt_create(uint16_t cols, uint16_t rows, uint32_t cw, uint32_t ch,
                           StudioVTReplyFn reply, void *userdata) {
  StudioVT *ctx = (StudioVT *)calloc(1, sizeof(*ctx));
  if (!ctx) return NULL;
  if (ghostty_terminal_new(NULL, &ctx->terminal, cols, rows) != GHOSTTY_SUCCESS ||
      ghostty_render_state_new(NULL, &ctx->render) != GHOSTTY_SUCCESS ||
      ghostty_key_encoder_new(NULL, &ctx->encoder) != GHOSTTY_SUCCESS ||
      ghostty_key_event_new(NULL, &ctx->event) != GHOSTTY_SUCCESS ||
      ghostty_mouse_encoder_new(NULL, &ctx->mouse_encoder) != GHOSTTY_SUCCESS ||
      ghostty_mouse_event_new(NULL, &ctx->mouse_event) != GHOSTTY_SUCCESS) {
    studio_vt_free(ctx);
    return NULL;
  }
  ctx->reply = reply;
  ctx->userdata = userdata;
  ctx->cell_width_px = cw; ctx->cell_height_px = ch;
  ctx->write_callback = studio_vt_write;
  GhosttyColorRgb fg = {255,255,255}, bg = {0,0,0};
  if (ghostty_terminal_resize(ctx->terminal, cols, rows, cw, ch) != GHOSTTY_SUCCESS ||
      ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg) != GHOSTTY_SUCCESS ||
      ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg) != GHOSTTY_SUCCESS ||
      ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, ctx) != GHOSTTY_SUCCESS ||
      ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, ctx->write_callback) != GHOSTTY_SUCCESS) { studio_vt_free(ctx); return NULL; }
  GhosttyTerminalModeConfig grapheme = { .mode = GHOSTTY_MODE_GRAPHEME_CLUSTER, .value = true };
  if (ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &grapheme) != GHOSTTY_SUCCESS) { studio_vt_free(ctx); return NULL; }
  return ctx;
}

void studio_vt_free(StudioVT *ctx) {
  if (!ctx) return;
  ghostty_key_event_free(ctx->event);
  ghostty_key_encoder_free(ctx->encoder);
  ghostty_mouse_event_free(ctx->mouse_event);
  ghostty_mouse_encoder_free(ctx->mouse_encoder);
  ghostty_selection_gesture_free(ctx->selection_gesture, ctx->terminal);
  ghostty_render_state_free(ctx->render);
  ghostty_terminal_free(ctx->terminal);
  free(ctx->reply_bytes);
  free(ctx);
}

void studio_vt_feed(StudioVT *ctx, const uint8_t *bytes, size_t len) {
  if (ctx && ctx->terminal && bytes && len) ghostty_terminal_vt_write(ctx->terminal, bytes, len);
}

GhosttyResult studio_vt_resize(StudioVT *ctx, uint16_t cols, uint16_t rows, uint32_t cw, uint32_t ch) {
  if (!ctx) return GHOSTTY_INVALID_VALUE;
  GhosttyResult result = ghostty_terminal_resize(ctx->terminal, cols, rows, cw, ch); if (result == GHOSTTY_SUCCESS) { ctx->cell_width_px = cw; ctx->cell_height_px = ch; } return result;
}

GhosttyResult studio_vt_set_theme(StudioVT *ctx, const StudioVTTheme *theme) {
  if (!ctx || !theme || theme->size < sizeof(*theme)) return GHOSTTY_INVALID_VALUE;
  GhosttyResult result = GHOSTTY_SUCCESS;
  if (theme->has_foreground) result = ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &theme->foreground);
  if (result != GHOSTTY_SUCCESS) return result;
  if (theme->has_background) result = ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &theme->background);
  if (result != GHOSTTY_SUCCESS) return result;
  if (theme->has_cursor) result = ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &theme->cursor);
  if (result != GHOSTTY_SUCCESS) return result;
  if (theme->has_palette) result = ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, theme->palette);
  return result;
}

static int append_bytes(uint8_t **buf, size_t *len, size_t *cap, const void *src, size_t n, size_t limit) {
  if (n > limit - *len) return 0;
  if (*len + n > *cap) {
    size_t next = *cap ? *cap : 256;
    while (next < *len + n) next *= 2;
    uint8_t *grown = (uint8_t *)realloc(*buf, next);
    if (!grown) return 0;
    *buf = grown; *cap = next;
  }
  memcpy(*buf + *len, src, n); *len += n; return 1;
}

GhosttyResult studio_vt_snapshot(StudioVT *ctx, StudioVTSnapshot *out) {
  if (!ctx || !out || out->size < sizeof(*out)) return GHOSTTY_INVALID_VALUE;
  memset((char *)out + sizeof(size_t), 0, sizeof(*out) - sizeof(size_t));
  GhosttyResult result = ghostty_render_state_update(ctx->render, ctx->terminal);
  if (result != GHOSTTY_SUCCESS) return result;
  uint16_t cols = 0, rows = 0;
  if (ghostty_render_state_get(ctx->render, GHOSTTY_RENDER_STATE_DATA_COLS, &cols) != GHOSTTY_SUCCESS ||
      ghostty_render_state_get(ctx->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) != GHOSTTY_SUCCESS) return GHOSTTY_INVALID_VALUE;
  out->cols = cols; out->rows = rows; out->cell_count = (size_t)cols * rows;
  out->cells = (StudioVTCell *)calloc(out->cell_count ? out->cell_count : 1, sizeof(*out->cells));
  if (!out->cells) return GHOSTTY_OUT_OF_MEMORY;
  for (size_t i = 0; i < out->cell_count; i++) out->cells[i].size = sizeof(StudioVTCell);
  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  (void)ghostty_render_state_get(ctx->render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
  out->colors = colors; out->colors.size = sizeof(out->colors);
  GhosttyRenderStateCursor cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
  (void)ghostty_render_state_get(ctx->render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
  out->cursor = cursor; out->cursor.size = sizeof(out->cursor);
  (void)ghostty_terminal_get(ctx->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &out->scrollbar);
  GhosttyRenderStateRowIterator iterator = NULL; GhosttyRenderStateRowCells cells = NULL;
  if (ghostty_render_state_row_iterator_new(NULL, &iterator) != GHOSTTY_SUCCESS) { studio_vt_snapshot_free(out); return GHOSTTY_OUT_OF_MEMORY; }
  if (ghostty_render_state_row_cells_new(NULL, &cells) != GHOSTTY_SUCCESS) { ghostty_render_state_row_iterator_free(iterator); studio_vt_snapshot_free(out); return GHOSTTY_OUT_OF_MEMORY; }
  if (ghostty_render_state_get(ctx->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) != GHOSTTY_SUCCESS) { ghostty_render_state_row_cells_free(cells); ghostty_render_state_row_iterator_free(iterator); studio_vt_snapshot_free(out); return GHOSTTY_INVALID_VALUE; }
  size_t text_len = 0, text_cap = 0;
  bool have_row = ghostty_render_state_row_iterator_next(iterator);
  for (uint16_t y = 0; y < rows && have_row; y++, have_row = ghostty_render_state_row_iterator_next(iterator)) {
    if (ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) != GHOSTTY_SUCCESS) continue;
    for (uint16_t x = 0; x < cols; x++) {
      if (ghostty_render_state_row_cells_select(cells, x) != GHOSTTY_SUCCESS) continue;
      StudioVTCell *cell = &out->cells[(size_t)y * cols + x];
      uint32_t required = 0; (void)ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &required);
      uint8_t utf8[256]; size_t n = sizeof(utf8); uint8_t *dynamic = NULL;
      GhosttyBuffer buffer = { .ptr = utf8, .len = 0, .cap = sizeof(utf8) };
      GhosttyResult utf_result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer);
      if (utf_result == GHOSTTY_OUT_OF_SPACE) {
        dynamic = (uint8_t *)malloc(buffer.len); if (!dynamic) { studio_vt_snapshot_free(out); ghostty_render_state_row_cells_free(cells); ghostty_render_state_row_iterator_free(iterator); return GHOSTTY_OUT_OF_MEMORY; }
        buffer.ptr = dynamic; buffer.cap = buffer.len; buffer.len = 0;
        utf_result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer);
      }
      if (utf_result != GHOSTTY_SUCCESS) { free(dynamic); continue; }
      n = buffer.len;
      cell->text_offset = text_len; cell->text_len = n;
      if (!append_bytes(&out->text, &text_len, &text_cap, dynamic ? dynamic : utf8, n, SIZE_MAX)) { free(dynamic); studio_vt_snapshot_free(out); ghostty_render_state_row_cells_free(cells); ghostty_render_state_row_iterator_free(iterator); return GHOSTTY_OUT_OF_MEMORY; }
      free(dynamic);
      GhosttyCell raw = 0;
      (void)ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
      (void)ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &cell->wide);
      cell->style = GHOSTTY_INIT_SIZED(GhosttyStyle);
      (void)ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &cell->style);
      cell->style.size = sizeof(cell->style);
      cell->has_background = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &cell->background) == GHOSTTY_SUCCESS;
      cell->has_foreground = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &cell->foreground) == GHOSTTY_SUCCESS;
      if (!cell->has_background) { cell->background = out->colors.background; cell->has_background = true; }
      if (!cell->has_foreground) { cell->foreground = out->colors.foreground; cell->has_foreground = true; }
      cell->has_underline = cell->style.underline_color.tag != GHOSTTY_STYLE_COLOR_NONE;
      cell->selected = false;
      (void)ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &cell->selected);
      if (cell->has_underline) {
        if (cell->style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB) cell->underline = cell->style.underline_color.value.rgb;
        else if (cell->style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE) cell->underline = out->colors.palette[cell->style.underline_color.value.palette];
      }
    }
  }
  out->text_len = text_len;
  size_t viewport_cap = 0;
  for (size_t i = 0; i < out->cell_count; i++) {
    if (i && i % cols == 0) { const uint8_t nl = '\n'; if (!append_bytes(&out->viewport_text, &out->viewport_text_len, &viewport_cap, &nl, 1, 65536)) { out->viewport_text_truncated = true; break; } }
    if (out->cells[i].text_len) { if (!append_bytes(&out->viewport_text, &out->viewport_text_len, &viewport_cap, out->text + out->cells[i].text_offset, out->cells[i].text_len, 65536)) { out->viewport_text_truncated = true; break; } }
    else if (out->cells[i].wide != GHOSTTY_CELL_WIDE_SPACER_TAIL && out->cells[i].wide != GHOSTTY_CELL_WIDE_SPACER_HEAD) { const uint8_t space = ' '; if (!append_bytes(&out->viewport_text, &out->viewport_text_len, &viewport_cap, &space, 1, 65536)) { out->viewport_text_truncated = true; break; } }
  }
  ghostty_render_state_row_cells_free(cells); ghostty_render_state_row_iterator_free(iterator);
  ghostty_render_state_clean(ctx->render);
  return GHOSTTY_SUCCESS;
}

void studio_vt_snapshot_free(StudioVTSnapshot *snapshot) { if (!snapshot) return; size_t size = snapshot->size; free(snapshot->cells); free(snapshot->text); free(snapshot->viewport_text); memset(snapshot, 0, sizeof(*snapshot)); snapshot->size = size; }
void studio_vt_bytes_free(void *bytes) { free(bytes); }

void studio_vt_scroll_delta(StudioVT *ctx, intptr_t delta) {
  if (!ctx || !ctx->terminal) return;
  GhosttyTerminalScrollViewport b = { .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA };
  b.value.delta = delta; ghostty_terminal_scroll_viewport(ctx->terminal, b);
}
void studio_vt_scroll_to(StudioVT *ctx, size_t row) {
  if (!ctx || !ctx->terminal) return;
  GhosttyTerminalScrollViewport b = { .tag = GHOSTTY_SCROLL_VIEWPORT_ROW };
  b.value.row = row; ghostty_terminal_scroll_viewport(ctx->terminal, b);
}
void studio_vt_scroll_bottom(StudioVT *ctx) {
  if (!ctx || !ctx->terminal) return;
  GhosttyTerminalScrollViewport b = { .tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM };
  ghostty_terminal_scroll_viewport(ctx->terminal, b);
}

static GhosttyResult grid_at(StudioVT *ctx, uint16_t col, uint16_t row, GhosttyGridRef *out) {
  GhosttyPoint p = { .tag = GHOSTTY_POINT_TAG_VIEWPORT };
  p.value.coordinate.x = col; p.value.coordinate.y = row;
  return ghostty_terminal_grid_ref(ctx->terminal, p, out);
}
static GhosttyResult install_selection(StudioVT *ctx, GhosttySelection *selection) {
  return ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, selection);
}
GhosttyResult studio_vt_selection_begin(StudioVT *ctx, uint16_t col, uint16_t row, int click_count) {
  if (!ctx || !ctx->terminal) return GHOSTTY_INVALID_VALUE;
  if (!ctx->selection_gesture && ghostty_selection_gesture_new(NULL, &ctx->selection_gesture) != GHOSTTY_SUCCESS) return GHOSTTY_OUT_OF_MEMORY;
  ghostty_selection_gesture_reset(ctx->selection_gesture, ctx->terminal);
  (void)ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
  GhosttySelectionGestureBehavior behavior = click_count >= 3 ? GHOSTTY_SELECTION_GESTURE_BEHAVIOR_LINE : (click_count == 2 ? GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD : GHOSTTY_SELECTION_GESTURE_BEHAVIOR_CELL);
  GhosttySelectionGestureEvent event = NULL; if (ghostty_selection_gesture_event_new(NULL, &event, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) != GHOSTTY_SUCCESS) return GHOSTTY_OUT_OF_MEMORY;
  GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef); GhosttyResult r = grid_at(ctx, col, row, &ref);
  if (r == GHOSTTY_SUCCESS) { r = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref); GhosttySurfacePosition position = { .x = col * (double)ctx->cell_width_px + 1.0, .y = row * (double)ctx->cell_height_px + 1.0 }; (void)ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position); GhosttySelectionGestureBehaviors behaviors = { behavior, behavior, behavior }; (void)ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS, &behaviors); }
  GhosttySelection s = GHOSTTY_INIT_SIZED(GhosttySelection); if (r == GHOSTTY_SUCCESS) r = ghostty_selection_gesture_event(ctx->selection_gesture, ctx->terminal, event, &s);
  ghostty_selection_gesture_event_free(event); if (r == GHOSTTY_NO_VALUE) { ctx->selection_active = true; return GHOSTTY_SUCCESS; } if (r != GHOSTTY_SUCCESS) return r; ctx->selection_active = true; return install_selection(ctx, &s);
}
GhosttyResult studio_vt_selection_update(StudioVT *ctx, uint16_t col, uint16_t row) {
  if (!ctx || !ctx->terminal || !ctx->selection_active) return GHOSTTY_INVALID_VALUE;
  if (!ctx->selection_gesture) return GHOSTTY_INVALID_VALUE;
  GhosttySelectionGestureEvent event = NULL; if (ghostty_selection_gesture_event_new(NULL, &event, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) != GHOSTTY_SUCCESS) return GHOSTTY_OUT_OF_MEMORY;
  GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef); GhosttyResult r = grid_at(ctx, col, row, &ref); if (r == GHOSTTY_SUCCESS) r = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
  GhosttySelectionGestureGeometry geometry = { .columns = 1, .cell_width = ctx->cell_width_px, .padding_left = 0, .screen_height = 1 }; uint16_t cols=1, rows=1; (void)ghostty_terminal_get(ctx->terminal,GHOSTTY_TERMINAL_DATA_COLS,&cols); (void)ghostty_terminal_get(ctx->terminal,GHOSTTY_TERMINAL_DATA_ROWS,&rows); geometry.columns=cols; geometry.screen_height=rows*ctx->cell_height_px; (void)ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY,&geometry); GhosttySurfacePosition position = { .x = col * (double)ctx->cell_width_px + 1.0, .y = row * (double)ctx->cell_height_px + 1.0 }; (void)ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position);
  GhosttySelection s = GHOSTTY_INIT_SIZED(GhosttySelection); if (r == GHOSTTY_SUCCESS) r = ghostty_selection_gesture_event(ctx->selection_gesture,ctx->terminal,event,&s); ghostty_selection_gesture_event_free(event); if(r!=GHOSTTY_SUCCESS)return r; return install_selection(ctx,&s);
}
GhosttyResult studio_vt_selection_end(StudioVT *ctx) {
  if (!ctx || !ctx->terminal || !ctx->selection_gesture || !ctx->selection_active) return GHOSTTY_INVALID_VALUE;
  GhosttySelectionGestureEvent event=NULL; if(ghostty_selection_gesture_event_new(NULL,&event,GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)!=GHOSTTY_SUCCESS)return GHOSTTY_OUT_OF_MEMORY; GhosttyResult r=ghostty_selection_gesture_event(ctx->selection_gesture,ctx->terminal,event,NULL); ghostty_selection_gesture_event_free(event); ctx->selection_active=false; return r==GHOSTTY_NO_VALUE?GHOSTTY_SUCCESS:r;
}
GhosttyResult studio_vt_select_drag(StudioVT *ctx, uint16_t sc, uint16_t sr, uint16_t ec, uint16_t er, int behavior) {
  if (!ctx || !ctx->terminal) return GHOSTTY_INVALID_VALUE;
  GhosttyGridRef start = GHOSTTY_INIT_SIZED(GhosttyGridRef), end = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  GhosttyResult r = grid_at(ctx, sc, sr, &start); if (r != GHOSTTY_SUCCESS) return r;
  r = grid_at(ctx, ec, er, &end); if (r != GHOSTTY_SUCCESS) return r;
  GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
  if (behavior == 1) {
    GhosttyTerminalSelectWordOptions a = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions), b = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
    GhosttySelection sa = GHOSTTY_INIT_SIZED(GhosttySelection), sb = GHOSTTY_INIT_SIZED(GhosttySelection); a.ref = start; b.ref = end;
    r = ghostty_terminal_select_word(ctx->terminal, &a, &sa); if (r == GHOSTTY_SUCCESS) r = ghostty_terminal_select_word(ctx->terminal, &b, &sb);
    if (r == GHOSTTY_SUCCESS) { selection.start = sa.start; selection.end = sb.end; selection.rectangle = false; }
  } else if (behavior == 2) {
    GhosttyTerminalSelectLineOptions a = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions), b = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
    GhosttySelection sa = GHOSTTY_INIT_SIZED(GhosttySelection), sb = GHOSTTY_INIT_SIZED(GhosttySelection); a.ref = start; b.ref = end; a.semantic_prompt_boundary = false; b.semantic_prompt_boundary = false;
    r = ghostty_terminal_select_line(ctx->terminal, &a, &sa); if (r == GHOSTTY_SUCCESS) r = ghostty_terminal_select_line(ctx->terminal, &b, &sb);
    if (r == GHOSTTY_SUCCESS) { selection.start = sa.start; selection.end = sb.end; selection.rectangle = false; }
  } else { selection.start = start; selection.end = end; selection.rectangle = false; r = GHOSTTY_SUCCESS; }
  return r == GHOSTTY_SUCCESS ? install_selection(ctx, &selection) : r;
}
GhosttyResult studio_vt_select_word(StudioVT *ctx, uint16_t col, uint16_t row) {
  if (!ctx || !ctx->terminal) return GHOSTTY_INVALID_VALUE;
  GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef); GhosttyResult r = grid_at(ctx, col, row, &ref); if (r != GHOSTTY_SUCCESS) return r;
  GhosttyTerminalSelectWordOptions o = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions); o.ref = ref;
  GhosttySelection s = GHOSTTY_INIT_SIZED(GhosttySelection); r = ghostty_terminal_select_word(ctx->terminal, &o, &s);
  return r == GHOSTTY_SUCCESS ? install_selection(ctx, &s) : r;
}
GhosttyResult studio_vt_select_line(StudioVT *ctx, uint16_t col, uint16_t row) {
  if (!ctx || !ctx->terminal) return GHOSTTY_INVALID_VALUE;
  GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef); GhosttyResult r = grid_at(ctx, col, row, &ref); if (r != GHOSTTY_SUCCESS) return r;
  GhosttyTerminalSelectLineOptions o = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions); o.ref = ref; o.semantic_prompt_boundary = false;
  GhosttySelection s = GHOSTTY_INIT_SIZED(GhosttySelection); r = ghostty_terminal_select_line(ctx->terminal, &o, &s);
  return r == GHOSTTY_SUCCESS ? install_selection(ctx, &s) : r;
}
GhosttyResult studio_vt_select_all(StudioVT *ctx) {
  if (!ctx || !ctx->terminal) return GHOSTTY_INVALID_VALUE;
  GhosttySelection s = GHOSTTY_INIT_SIZED(GhosttySelection); GhosttyResult r = ghostty_terminal_select_all(ctx->terminal, &s);
  return r == GHOSTTY_SUCCESS ? install_selection(ctx, &s) : r;
}
GhosttyResult studio_vt_clear_selection(StudioVT *ctx) {
  if (!ctx || !ctx->terminal) return GHOSTTY_INVALID_VALUE;
  return ghostty_terminal_set(ctx->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
}
GhosttyResult studio_vt_selected_text(StudioVT *ctx, uint8_t **out_bytes, size_t *out_len) {
  if (!ctx || !ctx->terminal || !out_bytes || !out_len) return GHOSTTY_INVALID_VALUE;
  *out_bytes = NULL; *out_len = 0;
  GhosttyTerminalSelectionFormatOptions o = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
  o.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN; o.unwrap = true; o.trim = true;
  size_t n = 0; GhosttyResult r = ghostty_terminal_selection_format_buf(ctx->terminal, o, NULL, 0, &n);
  if (r != GHOSTTY_OUT_OF_SPACE && r != GHOSTTY_SUCCESS) return r;
  uint8_t *p = (uint8_t *)malloc(n ? n : 1); if (!p) return GHOSTTY_OUT_OF_MEMORY;
  r = ghostty_terminal_selection_format_buf(ctx->terminal, o, p, n, &n); if (r != GHOSTTY_SUCCESS) { free(p); return r; }
  *out_bytes = p; *out_len = n; return GHOSTTY_SUCCESS;
}

static bool paste_reader(void *userdata, GhosttyString mime, GhosttyWriter writer) {
  (void)mime; StudioVT *ctx = (StudioVT *)userdata; if (!ctx) return false;
  return writer.write(writer.userdata, ctx->paste_bytes, ctx->paste_len);
}
GhosttyResult studio_vt_paste(StudioVT *ctx, const uint8_t *bytes, size_t len, bool allow_unsafe, bool *out_written) {
  if (!ctx || !ctx->terminal || (!bytes && len) || len > 262000) return GHOSTTY_INVALID_VALUE;
  ctx->paste_bytes = bytes; ctx->paste_len = len;
  GhosttyString mime = { (const uint8_t *)"text/plain", 10 };
  GhosttyPaste p = GHOSTTY_INIT_SIZED(GhosttyPaste); p.source = GHOSTTY_PASTE_SOURCE_TEXT; p.mimes = &mime; p.mimes_len = 1; p.reader = (GhosttyMimeReader){ paste_reader, ctx }; p.allow_unsafe = allow_unsafe;
  GhosttyResult r = ghostty_terminal_paste(ctx->terminal, &p, out_written);
  ctx->paste_bytes = NULL; ctx->paste_len = 0; return r;
}
GhosttyResult studio_vt_focus(StudioVT *ctx, bool focused, uint8_t **out_bytes, size_t *out_len) {
  if (!ctx || !ctx->terminal || !out_bytes || !out_len) return GHOSTTY_INVALID_VALUE; *out_bytes = NULL; *out_len = 0;
  GhosttyTerminalModeConfig mode = { GHOSTTY_MODE_FOCUS_EVENT, false };
  if (ghostty_terminal_get(ctx->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode) != GHOSTTY_SUCCESS || !mode.value) return GHOSTTY_NO_VALUE;
  size_t n = 0; GhosttyResult r = ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, NULL, 0, &n); if (r != GHOSTTY_OUT_OF_SPACE) return r;
  uint8_t *p = malloc(n); if (!p) return GHOSTTY_OUT_OF_MEMORY; r = ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, (char *)p, n, &n); if (r != GHOSTTY_SUCCESS) { free(p); return r; }
  *out_bytes = p; *out_len = n; return GHOSTTY_SUCCESS;
}
GhosttyResult studio_vt_mouse(StudioVT *ctx, int action, int button, uint32_t modifiers, double x, double y, uint32_t sw, uint32_t sh, uint32_t cw, uint32_t ch, uint32_t pt, uint32_t pb, uint32_t pl, uint32_t pr, uint8_t **out_bytes, size_t *out_len) {
  if (!ctx || !ctx->terminal || !out_bytes || !out_len) return GHOSTTY_INVALID_VALUE; *out_bytes = NULL; *out_len = 0;
  bool any_button_pressed = ctx->mouse_button_mask != 0;
    if (action == GHOSTTY_MOUSE_ACTION_MOTION && button == GHOSTTY_MOUSE_BUTTON_UNKNOWN && any_button_pressed) {
        for (int b = GHOSTTY_MOUSE_BUTTON_LEFT; b <= GHOSTTY_MOUSE_BUTTON_MIDDLE; ++b) {
            if (ctx->mouse_button_mask & ((uint32_t)1 << (b - GHOSTTY_MOUSE_BUTTON_LEFT))) { button = b; break; }
        }
    } if (action == GHOSTTY_MOUSE_ACTION_PRESS && button >= GHOSTTY_MOUSE_BUTTON_LEFT && button <= GHOSTTY_MOUSE_BUTTON_MIDDLE) { ctx->mouse_button_mask |= (uint32_t)1 << (button - GHOSTTY_MOUSE_BUTTON_LEFT); any_button_pressed = true; } else if (action == GHOSTTY_MOUSE_ACTION_RELEASE && button >= GHOSTTY_MOUSE_BUTTON_LEFT && button <= GHOSTTY_MOUSE_BUTTON_MIDDLE) { ctx->mouse_button_mask &= ~((uint32_t)1 << (button - GHOSTTY_MOUSE_BUTTON_LEFT)); any_button_pressed = ctx->mouse_button_mask != 0; }
  ghostty_mouse_encoder_setopt_from_terminal(ctx->mouse_encoder, ctx->terminal); ghostty_mouse_encoder_setopt(ctx->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any_button_pressed); GhosttyMouseEncoderSize size = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
  size.screen_width=sw; size.screen_height=sh; size.cell_width=cw; size.cell_height=ch; size.padding_top=pt; size.padding_bottom=pb; size.padding_left=pl; size.padding_right=pr; ghostty_mouse_encoder_setopt(ctx->mouse_encoder,GHOSTTY_MOUSE_ENCODER_OPT_SIZE,&size);
  ghostty_mouse_event_set_action(ctx->mouse_event, (GhosttyMouseAction)action); if (button <= 0) ghostty_mouse_event_clear_button(ctx->mouse_event); else ghostty_mouse_event_set_button(ctx->mouse_event,(GhosttyMouseButton)button); ghostty_mouse_event_set_mods(ctx->mouse_event,(GhosttyMods)modifiers); ghostty_mouse_event_set_position(ctx->mouse_event,(GhosttyMousePosition){(float)x,(float)y});
  size_t n=0; GhosttyResult r=ghostty_mouse_encoder_encode(ctx->mouse_encoder,ctx->mouse_event,NULL,0,&n); if(r!=GHOSTTY_OUT_OF_SPACE && r!=GHOSTTY_SUCCESS)return r; if(!n)return GHOSTTY_SUCCESS; uint8_t *p=malloc(n); if(!p)return GHOSTTY_OUT_OF_MEMORY; r=ghostty_mouse_encoder_encode(ctx->mouse_encoder,ctx->mouse_event,(char*)p,n,&n); if(r!=GHOSTTY_SUCCESS){free(p);return r;} *out_bytes=p;*out_len=n;return GHOSTTY_SUCCESS;
}
bool studio_vt_mouse_reporting(StudioVT *ctx) { bool v=false; if(ctx) (void)ghostty_terminal_get(ctx->terminal,GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,&v); return v; }
GhosttyResult studio_vt_pwd(StudioVT *ctx, uint8_t **out_bytes, size_t *out_len) { if(!ctx||!out_bytes||!out_len)return GHOSTTY_INVALID_VALUE; GhosttyString s={0}; GhosttyResult r=ghostty_terminal_get(ctx->terminal,GHOSTTY_TERMINAL_DATA_PWD,&s); if(r!=GHOSTTY_SUCCESS)return r; uint8_t*p=malloc(s.len?s.len:1);if(!p)return GHOSTTY_OUT_OF_MEMORY;memcpy(p,s.ptr,s.len);*out_bytes=p;*out_len=s.len;return GHOSTTY_SUCCESS; }

GhosttyResult studio_vt_encode_key(StudioVT *ctx, const StudioVTKey *key, uint8_t **out_bytes, size_t *out_len) {
  if (!ctx || !key || key->size < sizeof(*key) || !out_bytes || !out_len) return GHOSTTY_INVALID_VALUE;
  ghostty_key_event_set_action(ctx->event, key->action); ghostty_key_event_set_key(ctx->event, key->key); ghostty_key_event_set_mods(ctx->event, key->mods);
  ghostty_key_event_set_utf8(ctx->event, key->utf8, key->utf8_len);
  ghostty_key_event_set_unshifted_codepoint(ctx->event, key->unshifted_codepoint);
  size_t n = 0; ghostty_key_encoder_setopt_from_terminal(ctx->encoder, ctx->terminal);
  GhosttyResult result;
  result = ghostty_key_encoder_encode(ctx->encoder, ctx->event, NULL, 0, &n); if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) return result;
  uint8_t *bytes = (uint8_t *)malloc(n ? n : 1); if (!bytes) return GHOSTTY_OUT_OF_MEMORY;
  result = ghostty_key_encoder_encode(ctx->encoder, ctx->event, (char *)bytes, n, &n); if (result != GHOSTTY_SUCCESS) { free(bytes); return result; }
  *out_bytes = bytes; *out_len = n; return GHOSTTY_SUCCESS;
}
#endif
