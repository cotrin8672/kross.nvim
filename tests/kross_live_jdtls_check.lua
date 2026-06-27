local function main()
vim.opt.runtimepath:append(vim.fn.getcwd())

local function assertf(ok, message)
	if not ok then
		error(message, 2)
	end
end

local function write(path, lines)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(lines, path)
end

local function wait_for(message, timeout_ms, predicate)
	local ok = vim.wait(timeout_ms, predicate, 250)
	assertf(ok, message)
end

local plugin_root = vim.fn.getcwd()
local kross = require("kross")
kross.setup({ notify = false })

local kross_jar = vim.fn.globpath(plugin_root, "build/libs/kross-jdtls-*.jar", false, true)[1]
assertf(kross_jar and vim.fn.filereadable(kross_jar) == 1, "build the kross JDT LS jar first")

local mason_jdtls = vim.fs.joinpath(vim.env.LOCALAPPDATA, "nvim-data", "mason", "packages", "jdtls")
local launcher = vim.fn.globpath(mason_jdtls, "plugins/org.eclipse.equinox.launcher_*.jar", false, true)[1]
local config = vim.fs.joinpath(mason_jdtls, "config_win")
assertf(launcher and vim.fn.filereadable(launcher) == 1, "mason jdtls launcher not found")
assertf(vim.fn.isdirectory(config) == 1, "mason jdtls config_win not found")

local live_root = vim.fs.normalize(plugin_root .. "/build/kross-live-test")
vim.fn.delete(live_root, "rf")
local root = vim.fs.normalize(live_root .. "/sample")
local workspace = vim.fs.normalize(live_root .. "/jdtls-workspace")
print("kross live root: " .. root)
print("kross live workspace: " .. workspace)
vim.fn.mkdir(root, "p")
vim.fn.mkdir(workspace, "p")

write(root .. "/settings.gradle.kts", { 'rootProject.name = "kross-live"' })
write(root .. "/build.gradle.kts", {
	"plugins {",
	'    kotlin("jvm") version "2.1.0"',
	"    java",
	"}",
	"",
	"repositories {",
	"    mavenCentral()",
	"}",
})
write(root .. "/src/main/kotlin/demo/KotlinThing.kt", {
	"package demo",
	"",
	"class KotlinThing {",
	'    fun message(): String = "ok"',
	"}",
})
write(root .. "/src/main/java/demo/UseKotlin.java", {
	"package demo;",
	"",
	"public class UseKotlin {",
	"    public String call() {",
	"        return new KotlinThing().message();",
	"    }",
	"}",
})

local gradle = vim.system({ "gradle", "classes", "--no-daemon", "--quiet" }, { cwd = root, text = true }):wait()
assertf(gradle.code == 0, "gradle classes failed:\n" .. (gradle.stdout or "") .. (gradle.stderr or ""))
local kotlin_output = vim.fs.normalize(root .. "/build/classes/kotlin/main")
assertf(vim.fn.isdirectory(kotlin_output .. "/demo") == 1, "Kotlin classes were not produced")

local cmd = {
	"java",
	"-Declipse.application=org.eclipse.jdt.ls.core.id1",
	"-Dosgi.bundles.defaultStartLevel=4",
	"-Declipse.product=org.eclipse.jdt.ls.core.product",
	"-Dlog.protocol=true",
	"-Dlog.level=ALL",
	"-Xmx1G",
	"--add-modules=ALL-SYSTEM",
	"--add-opens",
	"java.base/java.util=ALL-UNNAMED",
	"--add-opens",
	"java.base/java.lang=ALL-UNNAMED",
	"-jar",
	launcher,
	"-configuration",
	config,
	"-data",
	workspace,
}

local diagnostics = {}
vim.diagnostic.handlers.kross_live = {
	show = function(_, bufnr, items)
		diagnostics[bufnr] = items
	end,
	hide = function(_, bufnr)
		diagnostics[bufnr] = {}
	end,
}

local client_id = vim.lsp.start({
	name = "jdtls",
	cmd = cmd,
	root_dir = root,
	workspace_folders = {
		{
			name = "kross-live",
			uri = vim.uri_from_fname(root),
		},
	},
	init_options = {
		bundles = { kross_jar },
	},
	settings = {
		java = {
			import = {
				gradle = {
					enabled = true,
				},
			},
		},
	},
})
assertf(client_id, "failed to start jdtls")

vim.cmd("edit " .. vim.fn.fnameescape(root .. "/src/main/java/demo/UseKotlin.java"))
local bufnr = vim.api.nvim_get_current_buf()
vim.lsp.buf_attach_client(bufnr, client_id)
local client = vim.lsp.get_client_by_id(client_id)
assertf(client, "jdtls client not found after start")
wait_for("jdtls did not initialize", 30000, function()
	return client.initialized
end)

local classpath = root .. "/.classpath"
wait_for("jdtls did not import the Gradle Java project", 90000, function()
	return vim.fn.filereadable(classpath) == 1 and table.concat(vim.fn.readfile(classpath), "\n"):find("src/main/java", 1, true)
end)

local before = table.concat(vim.fn.readfile(classpath), "\n")
assertf(not before:find("build/classes/kotlin/main", 1, true), "kross output was already on the classpath before attach")

wait_for("kross automatic attach did not write Kotlin output to the JDT classpath", 90000, function()
	if vim.fn.filereadable(classpath) ~= 1 then
		return false
	end
	return table.concat(vim.fn.readfile(classpath), "\n"):find("build/classes/kotlin/main", 1, true) ~= nil
end)

vim.cmd("edit " .. vim.fn.fnameescape(root .. "/src/main/java/demo/UseKotlin.java"))
vim.cmd("write")
bufnr = vim.api.nvim_get_current_buf()
vim.lsp.buf_attach_client(bufnr, client_id)

wait_for("JDT LS completion cannot see KotlinThing.message", 90000, function()
	local result = client:request_sync("textDocument/completion", {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		position = { line = 4, character = 33 },
	}, 10000, bufnr)
	if not result or result.err or not result.result then
		return false
	end
	local items = result.result.items or result.result
	for _, item in ipairs(items) do
		if item.label == "message()" or item.label == "message" then
			return true
		end
	end
	return false
end)

wait_for("Java diagnostics still report KotlinThing as unresolved", 90000, function()
	local items = vim.diagnostic.get(bufnr)
	for _, item in ipairs(items) do
		if item.severity == vim.diagnostic.severity.ERROR and tostring(item.message):find("KotlinThing", 1, true) then
			return false
		end
	end
	return true
end)

client:stop(true)
print("kross live jdtls check ok: " .. root)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
	vim.api.nvim_err_writeln(err)
	vim.cmd("cquit")
end
