/**
 * 官网要用的那几张 App 截图的名字。
 *
 * 单独放一个文件，是因为它同时被 `PhoneMock`（贴图）和 `FeatureBlock`
 * （功能段决定贴哪张）使用，两处必须对得上。
 *
 * 图不是手画的：由 `test/tools/render/render_shots_test.dart` 用 App 自己的
 * 代码渲染出来，落在 `public/shots/`（中文）与 `public/shots/en/`（英文）。
 */
export type Shot = 'list' | 'chat' | 'contacts' | 'discover' | 'group-call';

export const SHOT_FILES: Record<Shot, string> = {
  list: 'list.png',
  chat: 'chat.png',
  contacts: 'contacts.png',
  discover: 'discover.png',
  'group-call': 'group-call.png',
};
