# kross.nvim

Neovim glue for using Kotlin build output from `jdtls`.

This plugin has two small parts:

- a Neovim plugin that runs a local Kotlin/Gradle build and watches `*.kt` / `*.kts` saves
- a JDT LS extension jar that adds `build/classes/kotlin/main` to the Java classpath

## Requirements

- Neovim 0.10 or newer
- `jdtls`
- Java 21 for building the extension jar
- Gradle, or a project-local `gradlew` / `gradlew.bat`

## Installation

Build the local JDT LS extension jar first:

```sh
gradle jar --no-daemon
```

Then add the plugin and pass the jar to `jdtls` bundles.

### lazy.nvim

```lua
{
  "cotrin8672/kross.nvim",
  build = "gradle jar --no-daemon",
  config = function()
    require("kross").setup()
  end,
}
```

In your `jdtls` setup:

```lua
local kross = require("kross")

require("jdtls").start_or_attach({
  cmd = { "jdtls" },
  root_dir = vim.fs.root(0, { "settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts", ".git" }),
  init_options = {
    bundles = kross.bundles(),
  },
})
```

`kross.bundles()` checks the bundled extension jar before returning it. If the jar
is missing or older than the plugin Java/Gradle sources, kross runs
`gradle jar --no-daemon` from the plugin directory first. This prevents `jdtls`
from loading a stale extension jar after a plugin update.

## Usage

`require("kross").setup()` registers the integration.

On `jdtls` attach, kross looks for:

```text
build/classes/kotlin/main
```

If it exists, kross asks the bundled JDT LS extension to add it to the Java classpath.

Commands:

- `:KrossBuild` runs the local build
- `:KrossWatchStart` enables build-on-save for the current `jdtls` root
- `:KrossWatchStop` disables build-on-save for the current `jdtls` root

By default, kross watches Kotlin files after `jdtls` attaches and runs:

```sh
gradle classes
```

If the project has `gradlew` or `gradlew.bat`, kross uses that instead.

## Configuration

```lua
require("kross").setup({
  watch = true,
  build_on_attach = false,
  build_args = { "classes" },
  plugin_auto_build = true,
  plugin_build_args = { "jar", "--no-daemon" },
  debounce_ms = 300,
  notify = true,
  -- build_command = "gradle",
  -- plugin_build_command = "gradle",
})
```

## 日本語

`kross.nvim` は、Kotlin のローカルビルド成果物を `jdtls` から見えるようにするための Neovim プラグインです。

中身は小さく分かれています。

- Neovim 側: `*.kt` / `*.kts` の保存を監視し、ローカル Gradle build を実行します
- JDT LS 拡張 jar 側: `build/classes/kotlin/main` を Java classpath に追加します

## 必要なもの

- Neovim 0.10 以上
- `jdtls`
- 拡張 jar のビルド用 Java 21
- Gradle、または対象プロジェクト内の `gradlew` / `gradlew.bat`

## 導入方法

まず JDT LS 拡張 jar をローカルでビルドします。

```sh
gradle jar --no-daemon
```

その後、Neovim プラグインとして追加し、生成された jar を `jdtls` の bundles に渡します。

### lazy.nvim

```lua
{
  "cotrin8672/kross.nvim",
  build = "gradle jar --no-daemon",
  config = function()
    require("kross").setup()
  end,
}
```

`jdtls` 側の設定例:

```lua
local kross = require("kross")

require("jdtls").start_or_attach({
  cmd = { "jdtls" },
  root_dir = vim.fs.root(0, { "settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts", ".git" }),
  init_options = {
    bundles = kross.bundles(vim.fn.stdpath("data") .. "/lazy/kross.nvim/build/libs/kross-jdtls-0.2.0.jar"),
  },
})
```

プラグインマネージャーのインストール先が違う場合は、jar のパスを変更してください。

## 使い方

`require("kross").setup()` を呼ぶと連携が有効になります。

`jdtls` attach 時に kross は次のディレクトリを探します。

```text
build/classes/kotlin/main
```

存在する場合、同梱した JDT LS 拡張に依頼して Java classpath に追加します。

コマンド:

- `:KrossBuild`: ローカルビルドを実行
- `:KrossWatchStart`: 現在の `jdtls` root で保存時ビルドを有効化
- `:KrossWatchStop`: 現在の `jdtls` root で保存時ビルドを無効化

デフォルトでは、`jdtls` attach 後に Kotlin ファイルを監視し、保存時に次を実行します。

```sh
gradle classes
```

対象プロジェクトに `gradlew` または `gradlew.bat` がある場合は、そちらを優先します。

## 設定

```lua
require("kross").setup({
  watch = true,
  build_on_attach = false,
  build_args = { "classes" },
  debounce_ms = 300,
  notify = true,
  -- build_command = "gradle",
})
```
