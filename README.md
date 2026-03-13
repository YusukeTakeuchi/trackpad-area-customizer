# trackpad-area-customizer

Mac のトラックパッド座標を使って、左クリックを `Cmd+クリック` に変換する常駐ツールです。  
この実装では「トラックパッド左上ゾーン」で押したクリックのみを変換します。

## 仕組み

- `MultitouchSupport` (Private Framework) からトラックパッドの正規化座標 (0.0-1.0) を取得
- `CGEventTap` で左クリック (`leftMouseDown`) をフック
- 座標が指定ゾーン内なら `Cmd` フラグを付けてイベントを通す

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

SwiftPM のデバッグビルドでそのまま起動:

```bash
swift run trackpad-area-customizer
```

デバッグログを有効化して起動:

```bash
swift run trackpad-area-customizer --debug
```

## 実行

```bash
.build/release/trackpad-area-customizer
```

### オプション

```text
--left-zone <0.0-1.0>       左端からの横幅比率 (default: 0.33)
--top-zone <0.0-1.0>        上端からの縦幅比率 (default: 0.33)
--max-touch-age-ms <ms>     クリック判定で使うタッチ情報の最大経過時間 (default: 120)
--invert-y                  上下判定が逆の場合に有効化
--debug                     クリックイベントごとのデバッグログを出力
--help
```

例: 左上 20% x 25% だけを `Cmd+クリック` 化

```bash
.build/release/trackpad-area-customizer --left-zone 0.2 --top-zone 0.25
```

デバッグログを有効化:

```bash
.build/release/trackpad-area-customizer --debug
```

## 注意

- `MultitouchSupport` は Private Framework なので将来の macOS で動かなくなる可能性があります。
- うまく反応しない場合は `--invert-y` と `--max-touch-age-ms` を調整してください。
