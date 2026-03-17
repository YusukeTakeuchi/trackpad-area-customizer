# trackpad-area-customizer

Mac のトラックパッド座標を使って、左クリックを変換する常駐ツールです。  
エリア条件を JSON で定義し、条件ごとにアクションを割り当てます。

## 仕組み

- `MultitouchSupport` (Private Framework) からトラックパッドの正規化座標 (0.0-1.0) を取得
- `CGEventTap` で左クリック (`leftMouseDown` / `leftMouseUp`) をフック
- マッチしたルールに応じて以下を実行
  - `cmd+click` / `shift+click` / `ctrl+click` / `opt+click`: モディファイア付きクリックとして通す
  - それ以外: 指定ショートカットを送出（クリックは抑制）

## 前提

- macOS (Apple Silicon / Intel)
- `swift` コマンドが使えること
- 以下の権限を許可すること
  - Accessibility
  - Input Monitoring

## ビルド

```bash
swift build -c release
```

## 開発時の実行

```bash
swift run trackpad-area-customizer --config ./config.json
```

デバッグログ付き:

```bash
swift run trackpad-area-customizer --config ./config.json --debug
```

## 実行

```bash
.build/release/trackpad-area-customizer --config ./config.json
```

## オプション

```text
--config <path>         JSON rules file path (required)
--max-touch-age-ms <ms>     クリック判定で使うタッチ情報の最大経過時間 (default: 120)
--miss-click-history-seconds <s> missClickMargin 判定で使う履歴時間(秒) (default: 1.0)
--highlight-status-item      対象エリアにタッチ中、メニューバー項目の色を変更
--debug                     クリックイベントごとのデバッグログを出力
--help
```

## config.json 形式

```json
[
  {
    "area": ["0.3 < x < 0.8"],
    "shortcut": "f12",
    "missClickMargin": 0.03
  },
  {
    "area": ["0.8 < x", "y < 0.2"],
    "shortcut": "cmd+click"
  }
]
```

- ルールは上から順に評価し、最初に一致したルールを適用
- `area` の式は `x` / `y` に対して `<`, `<=`, `>`, `>=` を使用
- `shortcut` は `cmd+click`, `shift+click`, `ctrl+click`, `opt+click`, `cmd+c`, `cmd+shift+v`, `f1`-`f20` などを指定可能
- `missClickMargin` は省略可 (default: `0.03`)。`0` より大きい場合、対象エリア外側のマージン帯に `--miss-click-history-seconds` 以内で触れていたときはミスクリックとしてパススルーします。いったんミスクリック判定になると、同じ領域内のクリックは「領域外がタップされる」か「`recentHistory` 件数が `maxSnapshotHistory / 4` 未満になる」までパススルーを継続します。

## 注意

- `MultitouchSupport` は Private Framework なので将来の macOS で動かなくなる可能性があります。
- うまく反応しない場合は `--max-touch-age-ms`（クリック判定）と `--miss-click-history-seconds`（ミスクリック判定）を調整してください。
