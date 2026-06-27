vim.opt.runtimepath:append(vim.fn.getcwd())

local kross = require("kross")

kross.setup({ notify = false })
kross.setup({ notify = false })

local original_globpath = vim.fn.globpath
local original_filereadable = vim.fn.filereadable
vim.fn.globpath = function()
	return { "fake-kross.jar" }
end
vim.fn.filereadable = function(path)
	return path == "fake-kross.jar" and 1 or 0
end
assert(kross.bundles()[1] == "fake-kross.jar", "bundles finds the bundled JDT LS jar")
vim.fn.globpath = original_globpath
vim.fn.filereadable = original_filereadable

assert(vim.fn.exists(":KrossBuild") == 2, "KrossBuild command exists")
assert(vim.fn.exists(":KrossWatchStart") == 2, "KrossWatchStart command exists")
assert(vim.fn.exists(":KrossWatchStop") == 2, "KrossWatchStop command exists")

local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(root .. "/build/classes/kotlin/main", "p")
vim.fn.writefile({ "@echo off" }, root .. "/gradlew.bat")

local requests = {}
local client = {
	name = "jdtls",
	config = { root_dir = root },
	request = function(_, method, params, callback)
		table.insert(requests, { method = method, params = params })
		callback(nil)
	end,
}

local original_get_clients = vim.lsp.get_clients
local original_jobstart = vim.fn.jobstart
local started

vim.lsp.get_clients = function(opts)
	if opts and opts.name == "jdtls" then
		return { client }
	end
	return {}
end

vim.fn.jobstart = function(args, opts)
	started = { args = args, cwd = opts.cwd }
	opts.on_exit(1, 0)
	return 1
end

kross.build(root)

vim.wait(1000, function()
	return #requests == 1
end)

assert(started, "build command started")
assert(started.cwd == root, "build runs in project root")
assert(started.args[1]:match("gradlew%.bat$"), "build prefers local Gradle wrapper")
assert(started.args[2] == "classes", "build runs local classes task")
assert(requests[1].method == "workspace/executeCommand", "build success reattaches Kotlin output")
assert(requests[1].params.command == "kotlin.java.setKotlinBuildOutput", "attach uses kross JDT LS command")
assert(requests[1].params.arguments[1] == root .. "/build/classes/kotlin/main", "attach passes Kotlin output")

started = nil
vim.fn.mkdir(root .. "/src/main/kotlin", "p")
local kotlin_file = root .. "/src/main/kotlin/Foo.kt"
vim.fn.writefile({ "package demo" }, kotlin_file)
vim.cmd("edit " .. vim.fn.fnameescape(kotlin_file))

vim.lsp.get_clients = function(opts)
	if opts and opts.bufnr then
		return {}
	end
	if opts and opts.name == "jdtls" then
		return { client }
	end
	return {}
end

kross.watch(root)
vim.api.nvim_exec_autocmds("BufWritePost", { buffer = vim.api.nvim_get_current_buf(), modeline = false })
vim.wait(1000, function()
	return started ~= nil
end)

vim.lsp.get_clients = original_get_clients
vim.fn.jobstart = original_jobstart

assert(started, "watcher builds Kotlin buffers that are not attached to jdtls")
assert(started.cwd == root, "unattached Kotlin buffer watcher uses containing jdtls root")
