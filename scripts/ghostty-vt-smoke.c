#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <ghostty/vt.h>

static int contains_bytes(const uint8_t *haystack, size_t haystack_len,
                          const char *needle) {
  size_t needle_len = strlen(needle);
  if (needle_len > haystack_len) return 0;
  for (size_t i = 0; i <= haystack_len - needle_len; i++) {
    if (memcmp(haystack + i, needle, needle_len) == 0) return 1;
  }
  return 0;
}

/* Compile-time/API smoke coverage for M0. Runtime ownership and rendering
 * remain intentionally outside the app until the M1 backend is authorized. */
int main(void) {
  GhosttyTerminal terminal = NULL;
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, 80, 24);
  assert(result == GHOSTTY_SUCCESS && terminal != NULL);
  const uint8_t data[] = "\033[31mhello 你好\033[0m\r\n";
  ghostty_terminal_vt_write(terminal, data, sizeof(data) - 1);
  assert(ghostty_terminal_resize(terminal, 100, 30, 8, 16) == GHOSTTY_SUCCESS);

  GhosttyRenderState state = NULL;
  assert(ghostty_render_state_new(NULL, &state) == GHOSTTY_SUCCESS);
  assert(ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS);

  GhosttyFormatter formatter = NULL;
  GhosttyFormatterTerminalOptions options =
      GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
  options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  assert(ghostty_formatter_terminal_new(NULL, &formatter, terminal, options) == GHOSTTY_SUCCESS);
  uint8_t *formatted = NULL;
  size_t formatted_len = 0;
  assert(ghostty_formatter_format_alloc(formatter, NULL, &formatted, &formatted_len) == GHOSTTY_SUCCESS);
  assert(formatted_len > 0 && contains_bytes(formatted, formatted_len, "hello"));
  assert(contains_bytes(formatted, formatted_len, "你好"));
  ghostty_free(NULL, formatted, formatted_len);

  GhosttyKeyEncoder encoder = NULL;
  assert(ghostty_key_encoder_new(NULL, &encoder) == GHOSTTY_SUCCESS);
  GhosttyKeyEvent event = NULL;
  assert(ghostty_key_event_new(NULL, &event) == GHOSTTY_SUCCESS);
  ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS);
  ghostty_key_event_set_key(event, GHOSTTY_KEY_C);
  ghostty_key_event_set_mods(event, GHOSTTY_MODS_CTRL);
  char key_bytes[32];
  size_t key_len = 0;
  assert(ghostty_key_encoder_encode(encoder, event, key_bytes, sizeof(key_bytes), &key_len) == GHOSTTY_SUCCESS);
  assert(key_len == 1 && key_bytes[0] == 3);
  GhosttyMouseEncoder mouse = NULL;
  assert(ghostty_mouse_encoder_new(NULL, &mouse) == GHOSTTY_SUCCESS);
  uint16_t cols = 0;
  uint16_t rows = 0;
  assert(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols) == GHOSTTY_SUCCESS);
  assert(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) == GHOSTTY_SUCCESS);
  assert(cols == 100 && rows == 30);
  ghostty_key_event_free(event);
  ghostty_key_encoder_free(encoder);
  ghostty_mouse_encoder_free(mouse);
  ghostty_formatter_free(formatter);
  ghostty_render_state_free(state);
  ghostty_terminal_free(terminal);
  return 0;
}
