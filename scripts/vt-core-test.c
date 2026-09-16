#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../Web Studio/StudioVTCore.h"

static size_t replies;
static uint8_t last_reply[1024]; static size_t last_reply_len;
static int contains(const uint8_t *haystack, size_t haystack_len, const char *needle) {
  size_t n = strlen(needle);
  if (n > haystack_len) return 0;
  for (size_t i = 0; i + n <= haystack_len; i++) if (memcmp(haystack + i, needle, n) == 0) return 1;
  return 0;
}
static int ends_utf8(const uint8_t *p, size_t n) {
  size_t i=0; while(i<n) { uint8_t c=p[i++]; size_t e=c<0x80?0:(c<0xe0?1:(c<0xf0?2:3)); if(i+e>n)return 0; while(e--) if((p[i++]&0xc0)!=0x80)return 0; } return 1;
}
static void reply_cb(const uint8_t *bytes, size_t len, void *userdata) {
  (void)userdata;
  replies += len != 0;
  assert(len > 0 && bytes[0] == '\033');
  if (len <= sizeof(last_reply)) { memcpy(last_reply, bytes, len); last_reply_len = len; }
}

int main(void) {
  StudioVT *vt = studio_vt_create(20, 5, 8, 16, reply_cb, NULL);
  assert(vt);
  const uint8_t payload[] = "\033[31;48;2;1;2;3mA\033[7mB\033[0m\r\n中文 e\xCC\x81 \xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x92\xBB";
  studio_vt_feed(vt, payload, sizeof(payload) - 1);
  const uint8_t query[] = "\033[6n";
  studio_vt_feed(vt, query, sizeof(query) - 1);
  assert(replies > 0);

  StudioVTSnapshot snapshot = { .size = sizeof(snapshot) };
  assert(studio_vt_snapshot(vt, &snapshot) == GHOSTTY_SUCCESS);
  assert(snapshot.cols == 20 && snapshot.rows == 5 && snapshot.cell_count == 100);
  assert(snapshot.text_len > 0 && snapshot.viewport_text_len > 0);
  assert(contains(snapshot.text, snapshot.text_len, "中文"));
  assert(contains(snapshot.text, snapshot.text_len, "e\xCC\x81"));
  assert(snapshot.cells[0].has_foreground);
  assert(snapshot.cells[0].foreground.r > 0);
  assert(snapshot.cells[0].has_background);
  assert(snapshot.cells[0].style.fg_color.tag == GHOSTTY_STYLE_COLOR_PALETTE);
  assert(snapshot.cells[0].style.underline_color.tag == GHOSTTY_STYLE_COLOR_NONE);
  assert(snapshot.cells[1].style.inverse);
  assert(snapshot.cells[0].background.r == 1 && snapshot.cells[0].background.g == 2 && snapshot.cells[0].background.b == 3);
  studio_vt_snapshot_free(&snapshot);

  StudioVTTheme theme = { .size = sizeof(theme), .has_foreground = true, .has_background = true, .foreground = { 240, 240, 240 }, .background = { 9, 8, 7 } };
  assert(studio_vt_set_theme(vt, &theme) == GHOSTTY_SUCCESS);
  const uint8_t osc[] = "\033]11;rgb:aaaa/bbbb/cccc\007";
  studio_vt_feed(vt, osc, sizeof(osc) - 1);
  StudioVTSnapshot after_theme = { .size = sizeof(after_theme) };
  assert(studio_vt_snapshot(vt, &after_theme) == GHOSTTY_SUCCESS);
  assert(after_theme.colors.background.r == 0xaa);
  StudioVTTheme changed = { .size=sizeof(changed), .has_foreground=true, .has_background=true, .foreground={1,1,1}, .background={44,45,46} };
  assert(studio_vt_set_theme(vt, &changed) == GHOSTTY_SUCCESS);
  StudioVTSnapshot preserved={.size=sizeof(preserved)}; assert(studio_vt_snapshot(vt,&preserved)==GHOSTTY_SUCCESS && preserved.colors.background.r==0xaa); studio_vt_snapshot_free(&preserved);
  const uint8_t reset_osc[]="\033]111\007"; studio_vt_feed(vt,reset_osc,sizeof(reset_osc)-1);
  StudioVTSnapshot reset={.size=sizeof(reset)}; assert(studio_vt_snapshot(vt,&reset)==GHOSTTY_SUCCESS && reset.colors.background.r==44); studio_vt_snapshot_free(&reset);
  studio_vt_feed(vt,(const uint8_t*)"\033[?5h",6);
  StudioVTSnapshot reversed={.size=sizeof(reversed)}; assert(studio_vt_snapshot(vt,&reversed)==GHOSTTY_SUCCESS && reversed.colors.background.r==1 && reversed.colors.foreground.r==44); studio_vt_snapshot_free(&reversed);
  studio_vt_feed(vt,(const uint8_t*)"\033[?5l",6);
  StudioVTSnapshot normal={.size=sizeof(normal)}; assert(studio_vt_snapshot(vt,&normal)==GHOSTTY_SUCCESS && normal.colors.background.r==44 && normal.colors.foreground.r==1); studio_vt_snapshot_free(&normal);
  studio_vt_snapshot_free(&after_theme);
  assert(studio_vt_resize(vt, 30, 7, 9, 18) == GHOSTTY_SUCCESS);
  StudioVTSnapshot resized = { .size = sizeof(resized) };
  assert(studio_vt_snapshot(vt, &resized) == GHOSTTY_SUCCESS && resized.cols == 30 && resized.rows == 7);
  studio_vt_snapshot_free(&resized);
  StudioVTKey key = { .size = sizeof(key), .key = GHOSTTY_KEY_C, .action = GHOSTTY_KEY_ACTION_PRESS, .mods = GHOSTTY_MODS_CTRL };
  uint8_t *encoded = NULL; size_t encoded_len = 0;
  assert(studio_vt_encode_key(vt, &key, &encoded, &encoded_len) == GHOSTTY_SUCCESS);
  assert(encoded_len == 1 && encoded[0] == 3); studio_vt_bytes_free(encoded);
  uint8_t long_grapheme[1 + 200 * 2]; long_grapheme[0] = 'e';
  for (size_t i = 0; i < 200; i++) { long_grapheme[1 + i * 2] = 0xcc; long_grapheme[2 + i * 2] = 0x81; }
  studio_vt_feed(vt, long_grapheme, sizeof(long_grapheme));
  for (size_t i = 0; i < 70000; i++) studio_vt_feed(vt, (const uint8_t *)"x", 1);
  StudioVTSnapshot capped = { .size = sizeof(capped) };
  assert(studio_vt_snapshot(vt, &capped) == GHOSTTY_SUCCESS && capped.viewport_text_len <= 65536);
  if (capped.viewport_text_len) {
    size_t i = 0;
    while (i < capped.viewport_text_len) {
      uint8_t c = capped.viewport_text[i++];
      size_t extra = c < 0x80 ? 0 : (c < 0xE0 ? 1 : (c < 0xF0 ? 2 : 3));
      assert(i + extra <= capped.viewport_text_len);
      for (size_t j = 0; j < extra; j++) assert((capped.viewport_text[i++] & 0xC0) == 0x80);
    }
  }
  studio_vt_snapshot_free(&capped);
  StudioVT *wide = studio_vt_create(400, 200, 8, 16, NULL, NULL); assert(wide);
  for (size_t i=0;i<80000;i++) studio_vt_feed(wide,(const uint8_t*)"界",3);
  StudioVTSnapshot wide_snap={.size=sizeof(wide_snap)}; assert(studio_vt_snapshot(wide,&wide_snap)==GHOSTTY_SUCCESS && wide_snap.viewport_text_len>65000 && wide_snap.viewport_text_len<=65536 && ends_utf8(wide_snap.viewport_text,wide_snap.viewport_text_len));
  studio_vt_snapshot_free(&wide_snap); studio_vt_free(wide);
  StudioVT *history = studio_vt_create(20, 3, 8, 16, NULL, NULL); assert(history);
  studio_vt_feed(history,(const uint8_t*)"OLD_HISTORY_TOKEN\r\n",19);
  for (size_t i=0;i<8;i++) studio_vt_feed(history,(const uint8_t*)"x\r\n",3);
  studio_vt_feed(history,(const uint8_t*)"NEW_VISIBLE_TOKEN",17);
  StudioVTSnapshot hs={.size=sizeof(hs)}; assert(studio_vt_snapshot(history,&hs)==GHOSTTY_SUCCESS && !contains(hs.viewport_text,hs.viewport_text_len,"OLD_HISTORY_TOKEN") && contains(hs.viewport_text,hs.viewport_text_len,"NEW_VISIBLE_TOKEN")); studio_vt_snapshot_free(&hs); studio_vt_free(history);
  studio_vt_free(vt);
  StudioVT *long_vt = studio_vt_create(400, 2, 8, 16, NULL, NULL); assert(long_vt);
  uint8_t long_text[450]; for (size_t i=0;i<150;i++) { long_text[i*3]='e'; long_text[i*3+1]=0xcc; long_text[i*3+2]=0x81; }
  studio_vt_feed(long_vt, long_text, sizeof(long_text)); StudioVTSnapshot long_snap={.size=sizeof(long_snap)};
  assert(studio_vt_snapshot(long_vt,&long_snap)==GHOSTTY_SUCCESS && long_snap.text_len>256);
  assert(memcmp(long_snap.text,long_text,450)==0); studio_vt_feed(long_vt,(const uint8_t*)"Z",1); assert(long_snap.text[0]=='e'); studio_vt_snapshot_free(&long_snap); studio_vt_free(long_vt);
  StudioVT *cluster_vt = studio_vt_create(10, 2, 8, 16, NULL, NULL); assert(cluster_vt);
  uint8_t exact_grapheme[401]; exact_grapheme[0]='e'; for(size_t i=0;i<200;i++){exact_grapheme[1+i*2]=0xcc; exact_grapheme[2+i*2]=0x81;}
  studio_vt_feed(cluster_vt,exact_grapheme,sizeof(exact_grapheme)); StudioVTSnapshot cluster={.size=sizeof(cluster)};
  assert(studio_vt_snapshot(cluster_vt,&cluster)==GHOSTTY_SUCCESS);
  fprintf(stderr, "libghostty-vt grapheme cell bytes=%zu (input=%zu)\n", cluster.cells[0].text_len, sizeof(exact_grapheme));
  assert(cluster.cells[0].text_len > 0 && cluster.cells[0].text_len <= sizeof(exact_grapheme));
  studio_vt_snapshot_free(&cluster); studio_vt_free(cluster_vt);
  StudioVT *zwj = studio_vt_create(10, 2, 8, 16, NULL, NULL); assert(zwj);
  const uint8_t woman_technologist[] = "\xF0\x9F\x91\xa9\xE2\x80\x8D\xF0\x9F\x92\xbb";
  studio_vt_feed(zwj, woman_technologist, sizeof(woman_technologist) - 1);
  StudioVTSnapshot zwj_snapshot = { .size = sizeof(zwj_snapshot) };
  assert(studio_vt_snapshot(zwj, &zwj_snapshot) == GHOSTTY_SUCCESS);
  assert(zwj_snapshot.cells[0].text_len == sizeof(woman_technologist) - 1);
  assert(memcmp(zwj_snapshot.text + zwj_snapshot.cells[0].text_offset, woman_technologist, sizeof(woman_technologist) - 1) == 0);
  assert(zwj_snapshot.cells[0].wide == GHOSTTY_CELL_WIDE_WIDE && zwj_snapshot.cells[1].wide == GHOSTTY_CELL_WIDE_SPACER_TAIL);
  assert(zwj_snapshot.cursor.viewport_x == 2);
  studio_vt_snapshot_free(&zwj_snapshot);
  studio_vt_feed(zwj, (const uint8_t*)"\033[?2027l", 8);
  studio_vt_feed(zwj, woman_technologist, sizeof(woman_technologist) - 1);
  StudioVTSnapshot decomposed = { .size = sizeof(decomposed) };
  assert(studio_vt_snapshot(zwj, &decomposed) == GHOSTTY_SUCCESS && decomposed.cursor.viewport_x >= 2);
  studio_vt_snapshot_free(&decomposed);
  studio_vt_feed(zwj, (const uint8_t*)"\033c", 2);
  StudioVTSnapshot ris = { .size = sizeof(ris) };
  assert(studio_vt_snapshot(zwj, &ris) == GHOSTTY_SUCCESS && ris.cells[0].text_len == 0);
  studio_vt_feed(zwj, woman_technologist, sizeof(woman_technologist) - 1);
  StudioVTSnapshot restored = { .size = sizeof(restored) };
  assert(studio_vt_snapshot(zwj, &restored) == GHOSTTY_SUCCESS && restored.cursor.viewport_x == 2);
  studio_vt_snapshot_free(&restored);
  studio_vt_snapshot_free(&ris); studio_vt_free(zwj);
  StudioVT *interaction = studio_vt_create(40, 6, 8, 16, reply_cb, NULL); assert(interaction);
  studio_vt_feed(interaction, (const uint8_t*)"alpha beta\r\ngamma", 17);
  assert(studio_vt_selection_begin(interaction, 0, 0, 1) == GHOSTTY_SUCCESS);
  assert(studio_vt_selection_update(interaction, 5, 0) == GHOSTTY_SUCCESS);
  assert(studio_vt_selection_end(interaction) == GHOSTTY_SUCCESS);
  uint8_t *selected = NULL; size_t selected_len = 0;
  assert(studio_vt_selected_text(interaction, &selected, &selected_len) == GHOSTTY_SUCCESS && contains(selected, selected_len, "alpha")); studio_vt_bytes_free(selected);
  assert(studio_vt_set_theme(interaction, &changed) == GHOSTTY_SUCCESS); assert(studio_vt_resize(interaction, 40, 6, 9, 18) == GHOSTTY_SUCCESS);
  selected = NULL; selected_len = 0; assert(studio_vt_selected_text(interaction, &selected, &selected_len) == GHOSTTY_SUCCESS && contains(selected, selected_len, "alpha")); studio_vt_bytes_free(selected);
  studio_vt_feed(interaction, (const uint8_t*)"\033[?2004h", 8); bool wrote = false; last_reply_len = 0;
  assert(studio_vt_paste(interaction, (const uint8_t*)"PASTE", 5, false, &wrote) == GHOSTTY_SUCCESS && wrote); assert(last_reply_len == 17 && memcmp(last_reply, "\033[200~PASTE\033[201~", 17) == 0);
  studio_vt_feed(interaction, (const uint8_t*)"\033[?1004h", 8); assert(studio_vt_focus(interaction, true, &selected, &selected_len) == GHOSTTY_SUCCESS && selected_len == 3 && memcmp(selected, "\033[I", 3) == 0); studio_vt_bytes_free(selected);
  studio_vt_feed(interaction, (const uint8_t*)"\033[?1004l", 8); assert(studio_vt_focus(interaction, true, &selected, &selected_len) == GHOSTTY_NO_VALUE);
  studio_vt_feed(interaction, (const uint8_t*)"\033]7;file://host/tmp\007", strlen("\033]7;file://host/tmp\007")); assert(studio_vt_pwd(interaction, &selected, &selected_len) == GHOSTTY_SUCCESS && contains(selected, selected_len, "/tmp")); studio_vt_bytes_free(selected);
  uint8_t *mouse_bytes = NULL; size_t mouse_len = 0;
  assert(studio_vt_mouse(interaction, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, 0, 17, 33, 320, 96, 8, 16, 0, 0, 0, 0, &mouse_bytes, &mouse_len) == GHOSTTY_SUCCESS && mouse_len == 0);
  studio_vt_feed(interaction, (const uint8_t*)"\033[?1002h\033[?1006h", strlen("\033[?1002h\033[?1006h"));
  assert(studio_vt_mouse_reporting(interaction));
  const char *press_mouse = "\033[<0;3;3M"; assert(studio_vt_mouse(interaction, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, 0, 17, 33, 320, 96, 8, 16, 0, 0, 0, 0, &mouse_bytes, &mouse_len) == GHOSTTY_SUCCESS && mouse_len == strlen(press_mouse) && memcmp(mouse_bytes, press_mouse, mouse_len) == 0); studio_vt_bytes_free(mouse_bytes);
  const char *motion_mouse = "\033[<32;4;4M"; assert(studio_vt_mouse(interaction, GHOSTTY_MOUSE_ACTION_MOTION, 0, 0, 25, 49, 320, 96, 8, 16, 0, 0, 0, 0, &mouse_bytes, &mouse_len) == GHOSTTY_SUCCESS && mouse_len == strlen(motion_mouse) && memcmp(mouse_bytes, motion_mouse, mouse_len) == 0); studio_vt_bytes_free(mouse_bytes);
  const char *release_mouse = "\033[<0;3;3m"; assert(studio_vt_mouse(interaction, GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_LEFT, 0, 17, 33, 320, 96, 8, 16, 0, 0, 0, 0, &mouse_bytes, &mouse_len) == GHOSTTY_SUCCESS && mouse_len == strlen(release_mouse) && memcmp(mouse_bytes, release_mouse, mouse_len) == 0); studio_vt_bytes_free(mouse_bytes);
  studio_vt_free(interaction);
  StudioVT *gesture = studio_vt_create(24, 4, 8, 16, NULL, NULL); assert(gesture);
  const char *gesture_text = "alpha beta gamma\r\nline-two\r\nline-three\r\nline-four"; studio_vt_feed(gesture, (const uint8_t *)gesture_text, strlen(gesture_text));
  assert(studio_vt_selection_begin(gesture, 6, 0, 2) == GHOSTTY_SUCCESS); studio_vt_feed(gesture, (const uint8_t *)"\r\nscroll-one\r\nscroll-two", strlen("\r\nscroll-one\r\nscroll-two")); studio_vt_scroll_delta(gesture, -2); assert(studio_vt_selection_update(gesture, 0, 1) == GHOSTTY_SUCCESS); assert(studio_vt_selection_end(gesture) == GHOSTTY_SUCCESS);
  assert(studio_vt_selection_begin(gesture, 10, 0, 2) == GHOSTTY_SUCCESS); assert(studio_vt_selection_update(gesture, 4, 0) == GHOSTTY_SUCCESS); assert(studio_vt_selection_end(gesture) == GHOSTTY_SUCCESS);
  assert(studio_vt_selection_begin(gesture, 0, 0, 3) == GHOSTTY_SUCCESS); assert(studio_vt_selection_update(gesture, 12, 2) == GHOSTTY_SUCCESS); assert(studio_vt_selection_end(gesture) == GHOSTTY_SUCCESS);
  assert(studio_vt_selection_begin(gesture, 12, 2, 3) == GHOSTTY_SUCCESS); assert(studio_vt_selection_update(gesture, 0, 0) == GHOSTTY_SUCCESS); assert(studio_vt_selection_end(gesture) == GHOSTTY_SUCCESS); studio_vt_free(gesture);
  puts("studio VT core adapter passed");
  return 0;
}
