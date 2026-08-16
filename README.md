# ai-build-support

このリポジトリは iOS / macOS アプリ開発プロジェクトに **git submodule** として組み込む共通ビルド支援ツール群です。
このドキュメントは AI（Claude 等）が読んで正確に操作できるよう記述されています。

---

## 絶対に守るルール

> **`xcodegen generate` を直接呼んではならない。**

xcodegen は必ず `gen_build_install.zsh` 経由で実行される。AI が直接 `xcodegen` コマンドを実行することはいかなる理由があっても禁止。唯一の例外は `new_project.zsh` の内部（プロジェクト初期化時のみ）。

---

## ファイル構成

| ファイル | 役割 |
|---|---|
| `new_project.zsh` | 新規プロジェクトのブートストラップ（一度だけ実行） |
| `gen_build_install.zsh` | ビルド・インストール・アーカイブの統合スクリプト |
| `fetch_log.sh` | ログ取得 / Documents バックアップ・復元 |
| `build_config.example` | `.build_config` の記述例 |
| `project_template_ios.yml` | XcodeGen テンプレート（iOS） |
| `project_template_macos.yml` | XcodeGen テンプレート（macOS） |
| `xcodegen_base_ios.yml` | XcodeGen 共通設定（iOS） |
| `xcodegen_base_macos.yml` | XcodeGen 共通設定（macOS） |
| `gitignore_template` | `.gitignore` テンプレート |

---

## 1. 新規プロジェクトのセットアップ

空の git リポジトリを作成済みの状態から始める。

```zsh
# 1. リポジトリを作成して移動
git init my-app && cd my-app

# 2. new_project.zsh でブートストラップ（引数: AppName [ios|macos] [bundle-suffix]）
/path/to/ai-build-support/new_project.zsh MyApp ios myapp
# または
/path/to/ai-build-support/new_project.zsh MyApp macos myapp
```

`new_project.zsh` が自動で行うこと:
1. `ai-build-support` を git submodule として追加
2. `.build_config` を生成（BUNDLE_ID, LOG_NAME）
3. `project.yml` をテンプレートから生成
4. 最小限の SwiftUI ソースを生成（App, ContentView, Assets, PrivacyInfo, UITests）
5. `.gitignore` を設置
6. `xcodegen generate` を実行（この 1 回だけ直接呼ぶことが許可されている）
7. 初回コミットを作成

ブートストラップ完了後:
```zsh
gh repo create shinyaohtani/<repo-dir-name> --private --source=. --remote=origin
git push -u origin main
./ai-build-support/gen_build_install.zsh --build-check
```

---

## 2. 既存プロジェクトをクローンする

```zsh
# submodule を含めて一括取得（推奨）
git clone --recurse-submodules git@github.com:shinyaohtani/<repo>.git

# クローン後に初期化する場合
git clone git@github.com:shinyaohtani/<repo>.git
cd <repo>
git submodule update --init
```

`git pull` 後に submodule も追従させる:
```zsh
git pull
git submodule update
# または一括で:
git pull --recurse-submodules
```

---

## 3. `.build_config` — プロジェクト設定ファイル

プロジェクトルートに置く Shell スクリプト。`gen_build_install.zsh` と `fetch_log.sh` が `source` する。

### iOS アプリの場合
```sh
BUNDLE_ID="com.aabce.myapp"   # 必須: iOS のとき空でない値を設定
LOG_NAME="myapp_debug.log"    # fetch_log.sh で使うログファイル名
# DEVICE_NAME="iPhone 16 2024"  # 省略時のデフォルト
# BACKUP_ROOT="backups"          # 省略時のデフォルト
```

### macOS アプリの場合
```sh
BUNDLE_ID=""                  # 必須: macOS のとき空にする
NOTARY_PROFILE=""             # --release を使うとき設定（空なら --release 無効）
LOG_NAME="myapp_debug.log"    # fetch_log.sh で使うログファイル名
```

`BUNDLE_ID` が空かどうかで iOS / macOS を自動判定する。`SCHEME` は `*.xcodeproj` または `project.yml` の `name:` から自動検出するため通常は不要。

---

## 4. `gen_build_install.zsh` — ビルドとインストール

**必ずプロジェクトルートから呼ぶ。**

```zsh
./ai-build-support/gen_build_install.zsh [verbosity] <command> [args]
```

### 4-1. 共通オプション（verbosity）

| オプション | 効果 |
|---|---|
| （省略） | `==>` 進捗 + warnings/errors + `** BUILD ...` 結果のみ表示 |
| `--verbose` | xcodebuild の全出力を表示 |
| `--quiet` | warnings/errors のみ（`==>` 進捗を非表示） |

他のフラグの前後どちらでも指定できる:
```zsh
./ai-build-support/gen_build_install.zsh --quiet -n 'iPhone 16 2024'
./ai-build-support/gen_build_install.zsh -n 'iPhone 16 2024' --verbose
```

### 4-2. iOS コマンド（`BUNDLE_ID` が設定されているとき有効）

| コマンド | 動作 |
|---|---|
| `--list` | 接続中の iOS 実機一覧を表示 |
| `-n <device-name>` | デバイス名で実機にビルド & インストール |
| `-i <device-id>` | デバイス ID で実機にビルド & インストール |
| `--sim [name]` | シミュレータでビルド & 起動（デフォルト: `iPhone 17 Pro`） |
| `--archive` | App Store 用 `.ipa` をアーカイブ & エクスポート |
| `--build-check[=Debug,Release]` | インストールなしのビルド検査（デフォルト: Release） |

実機へのインストール手順:
```zsh
# 接続デバイスを確認
./ai-build-support/gen_build_install.zsh --list

# デバイス名でインストール
./ai-build-support/gen_build_install.zsh -n 'iPhone 16 2024'

# デバイス ID でインストール（ID は --list で確認）
./ai-build-support/gen_build_install.zsh -i 00008120-XXXXXXXXXXXX
```

### 4-3. macOS コマンド（`BUNDLE_ID` が空のとき有効）

| コマンド | 動作 |
|---|---|
| `--mac` | ビルドして `/Applications/<AppName>.app` にインストール |
| `--release [version]` | Developer ID 署名 → 公証 → staple → zip（`NOTARY_PROFILE` 必須） |
| `--build-check[=Debug,Release]` | インストールなしのビルド検査（デフォルト: Release） |

macOS アプリのインストール:
```zsh
./ai-build-support/gen_build_install.zsh --mac
```

### 4-4. `--build-check` の使い方

```zsh
# Release のみ（デフォルト）
./ai-build-support/gen_build_install.zsh --build-check

# Debug のみ
./ai-build-support/gen_build_install.zsh --build-check=Debug

# Debug と Release 両方
./ai-build-support/gen_build_install.zsh --build-check=Debug,Release
```

---

## 5. `fetch_log.sh` — ログ取得・ファイル操作

**必ずプロジェクトルートから呼ぶ。** `.build_config` に `BUNDLE_ID` と `LOG_NAME` が必要。

```zsh
./ai-build-support/fetch_log.sh [command] [args]
```

| コマンド | 動作 |
|---|---|
| （引数なし） | 実機の `Documents/<LOG_NAME>` を取得して `logs/debug/<session>.log` に保存 |
| `--sim` | 起動中シミュレータ（booted）から同上 |
| `--backup-docs` | 実機の `Documents/` フォルダ全体を `backups/<timestamp>/` にバックアップ |
| `--restore-docs [PATH]` | バックアップから実機に `Documents/` を復元（省略時は最新のバックアップ） |
| `--backup-appdata` | 実機のアプリデータ一式（`Documents/` + `Library/Application Support/`）をバックアップ |
| `--restore-appdata [PATH]` | バックアップからアプリデータ一式を復元（省略時は最新のバックアップ） |

> **SwiftData / CoreData を使うアプリは `--backup-appdata` を使うこと。**
> ストア（`default.store`, `-shm`, `-wal`）は `Documents/` ではなく
> `Library/Application Support/` に置かれるため、`--backup-docs` では
> 空のフォルダしか取れない。

ログ取得例:
```zsh
# 実機から
./ai-build-support/fetch_log.sh
# → logs/debug/2024-01-15T10:30:00.log などに保存される

# シミュレータから
./ai-build-support/fetch_log.sh --sim
```

Documents バックアップ:
```zsh
# バックアップ（実機の Documents/ 全体）
./ai-build-support/fetch_log.sh --backup-docs
# → backups/20240115-103000/Documents/ に保存

# 復元（最新バックアップから）
./ai-build-support/fetch_log.sh --restore-docs
# → 復元前にアプリをフォースクローズするよう促される

# 復元（特定のバックアップから）
./ai-build-support/fetch_log.sh --restore-docs backups/20240115-103000
```

---

## 6. ワークフロー早見表

### iOS アプリ開発の典型的な流れ

```
コード変更
    ↓
./ai-build-support/gen_build_install.zsh --build-check   ← ビルド確認
    ↓
./ai-build-support/gen_build_install.zsh -n 'iPhone 16 2024'  ← 実機インストール
    ↓
アプリ動作確認
    ↓
./ai-build-support/fetch_log.sh                          ← ログ回収
```

### macOS アプリ開発の典型的な流れ

```
コード変更
    ↓
./ai-build-support/gen_build_install.zsh --build-check
    ↓
./ai-build-support/gen_build_install.zsh --mac           ← /Applications にインストール
    ↓
アプリ動作確認
```

---

## 7. AI が犯しがちなミスと対処

| ミス | 正しい対応 |
|---|---|
| `xcodegen generate` を直接実行する | **禁止。** `gen_build_install.zsh` を呼ぶ |
| クローン後に submodule の初期化を忘れる | `git submodule update --init` を実行 |
| `gen_build_install.zsh` をサブモジュールの中から呼ぶ | プロジェクトルート（`.build_config` がある場所）から呼ぶ |
| iOS プロジェクトで `--mac` を使う | `BUNDLE_ID` が設定されているときは iOS モード。`--list` / `-n` / `-i` / `--sim` を使う |
| macOS プロジェクトで `-n` を使う | `BUNDLE_ID=""` のときは macOS モード。`--mac` を使う |
| `git pull` 後に古い submodule のままビルドする | `git pull --recurse-submodules` か `git submodule update` を実行 |
