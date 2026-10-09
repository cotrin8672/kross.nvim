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
assert(kross.bundles("fake-kross.jar")[1] == "fake-kross.jar", "bundles accepts an explicit JDT LS jar")
vim.fn.globpath = original_globpath
vim.fn.filereadable = original_filereadable

local original_getftime = vim.fn.getftime
local original_system = vim.system
local plugin_build
vim.fn.globpath = function(_, pattern)
	if pattern == "build/libs/kross-jdtls-*.jar" then
		return { "old-kross.jar", "new-kross.jar" }
	end
	return { "src/main/java/Kross.java" }
end
vim.fn.filereadable = function(path)
	return (path == "old-kross.jar" or path == "new-kross.jar") and 1 or 0
end
vim.fn.getftime = function(path)
	return ({ ["old-kross.jar"] = 10, ["new-kross.jar"] = 30 })[path] or 20
end
assert(kross.bundles()[1] == "new-kross.jar", "bundles returns the newest built JDT LS jar")

vim.fn.globpath = function(_, pattern)
	if pattern == "build/libs/kross-jdtls-*.jar" then
		return { "stale-kross.jar" }
	end
	return { "src/main/java/Kross.java" }
end
vim.fn.filereadable = function(path)
	return path == "stale-kross.jar" and 1 or 0
end
vim.fn.getftime = function(path)
	return path == "stale-kross.jar" and 10 or 20
end
vim.system = function(args, opts)
	plugin_build = { args = args, cwd = opts.cwd }
	return {
		wait = function()
			return { code = 0, stdout = "", stderr = "" }
		end,
	}
end
assert(kross.bundles()[1] == "stale-kross.jar", "bundles returns the bundled JDT LS jar")
assert(plugin_build, "stale bundled jar triggers plugin build")
assert(plugin_build.args[#plugin_build.args - 1] == "jar", "plugin build runs jar task")
assert(plugin_build.args[#plugin_build.args] == "--no-daemon", "plugin build disables Gradle daemon")
vim.fn.globpath = original_globpath
vim.fn.filereadable = original_filereadable
vim.fn.getftime = original_getftime
vim.system = original_system

assert(vim.fn.exists(":KrossBuild") == 2, "KrossBuild command exists")
assert(vim.fn.exists(":KrossWatchStart") == 2, "KrossWatchStart command exists")
assert(vim.fn.exists(":KrossWatchStop") == 2, "KrossWatchStop command exists")

local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(root .. "/build/classes/kotlin/main", "p")
vim.fn.writefile({ "@echo off" }, root .. "/gradlew.bat")

local requests = {}
local client = {
	name = "jdtls",
	offset_encoding = "utf-16",
	config = { root_dir = root },
	request = function(_, method, params, callback)
		table.insert(requests, { method = method, params = params })
		callback(nil)
	end,
}

local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_jobstart = vim.fn.jobstart
local started

vim.lsp.get_clients = function(opts)
	if opts and opts.name == "jdtls" then
		return { client }
	end
	return {}
end
vim.lsp.get_client_by_id = function()
	return client
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

local queued_jobs = {}
requests = {}
vim.fn.jobstart = function(args, opts)
	table.insert(queued_jobs, { args = args, cwd = opts.cwd, opts = opts })
	return #queued_jobs
end
kross.build(root)
kross.build(root)
assert(#queued_jobs == 1, "running build coalesces saves")
queued_jobs[1].opts.on_exit(1, 0)
vim.wait(1000, function()
	return #queued_jobs == 2
end)
assert(#queued_jobs == 2, "pending save reruns build after the current build")
queued_jobs[2].opts.on_exit(2, 0)

vim.fn.jobstart = function(args, opts)
	started = { args = args, cwd = opts.cwd }
	opts.on_exit(1, 0)
	return 1
end

requests = {}
vim.fn.writefile({
	[[<?xml version="1.0" encoding="UTF-8"?>]],
	[[<classpath>]],
	[[	<classpathentry kind="lib" path="]] .. root .. [[/build/classes/kotlin/main">]],
	[[		<attributes>]],
	[[			<attribute name="kross" value="true"/>]],
	[[		</attributes>]],
	[[	</classpathentry>]],
	[[</classpath>]],
}, root .. "/.classpath")
kross.attach(client)
assert(#requests == 1, "attach still registers JDT watcher when classpath already contains Kotlin output")
assert(requests[1].params.command == "kotlin.java.setKotlinBuildOutput", "existing Kotlin output still reaches JDT extension")

started = nil
vim.fn.mkdir(root .. "/src/main/kotlin", "p")
local kotlin_file = root .. "/src/main/kotlin/Foo.kt"
vim.fn.writefile({ "package demo", "class Foo {", "    fun message() = Unit", "}" }, kotlin_file)
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

vim.api.nvim_exec_autocmds("LspAttach", {
	buffer = vim.api.nvim_get_current_buf(),
	data = { client_id = 1 },
	modeline = false,
})
vim.wait(1000, function()
	local map = vim.fn.maparg("gd", "n", false, true)
	return map and map.desc == "kross Kotlin definition"
end)
assert(vim.fn.maparg("gd", "n", false, true).desc == "kross Kotlin definition", "kross remaps gd after jdtls attach")
assert(vim.fn.maparg("grr", "n", false, true).desc == "kross Kotlin references", "kross remaps grr after jdtls attach")

local original_buf_request_all = vim.lsp.buf_request_all
local definition_list
local references_list
local resolve_request
local standard_requested = false
vim.lsp.get_clients = function(opts)
	if opts and opts.name == "jdtls" then
		return { client }
	end
	return {}
end
vim.lsp.buf_request_all = function(_, method, _, callback)
	standard_requested = true
	assert(method == "textDocument/definition", "kross falls back to the standard JDT LS definition")
	callback({
		[1] = {
			result = {
				uri = vim.uri_from_fname(kotlin_file),
				range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 9 } },
			},
		},
	})
end
client.request = function(_, method, params, callback)
	resolve_request = { method = method, params = params }
	callback(nil, {
		uri = vim.uri_from_fname(kotlin_file),
		range = {
			start = { line = 1, character = 6 },
			["end"] = { line = 1, character = 9 },
		},
	})
end
vim.api.nvim_win_set_cursor(0, { 2, 7 })
kross.definition({
	on_list = function(list)
		definition_list = list
	end,
})
vim.wait(1000, function()
	return definition_list ~= nil
end)
assert(resolve_request.method == "workspace/executeCommand", "kross asks the JDT LS extension for Kotlin source")
assert(resolve_request.params.command == "kotlin.java.resolveKotlinSource", "kross uses the Kotlin source command")
assert(resolve_request.params.arguments[1].position.line == 1, "source lookup passes the cursor position")
assert(not standard_requested, "resolved Kotlin source bypasses the binary definition")
assert(vim.fs.normalize(definition_list.items[1].filename) == vim.fs.normalize(kotlin_file), "kross opens the source returned by the extension")

definition_list = nil
client.request = function(_, _, _, callback)
	callback(nil, nil)
end
kross.definition({
	on_list = function(list)
		definition_list = list
	end,
})
vim.wait(1000, function()
	return definition_list ~= nil
end)
assert(standard_requested, "missing Kotlin source falls back to the standard definition")

vim.lsp.buf_request_all = function(_, method, _, callback)
	assert(method == "textDocument/references", "kross references uses the standard JDT LS references request")
	callback({
		[1] = {
			result = {
				{
					uri = vim.uri_from_fname(kotlin_file),
					range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 9 } },
				},
				{
					uri = "jdt://contents/demo/KotlinThing.class?=sample",
					range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 9 } },
				},
			},
		},
	})
end
kross.references({
	on_list = function(list)
		references_list = list
	end,
})
vim.wait(1000, function()
	return references_list ~= nil
end)
assert(#references_list.items == 1, "kross references filters compiled JDT locations")
assert(vim.fs.normalize(references_list.items[1].filename) == vim.fs.normalize(kotlin_file), "kross references keeps real files")

local kotlin_client_request
local rename_request
local edit_applied
local kotlin_client = {
	name = "kotlin_lsp",
	offset_encoding = "utf-16",
	config = { root_dir = root:gsub("^([A-Z]):", function(drive)
		return drive:lower() .. ":"
	end) },
	request = function(_, method, params, callback)
		if method == "textDocument/references" then
			kotlin_client_request = { method = method, params = params }
			callback(nil, {
				{
					uri = vim.uri_from_fname(kotlin_file),
					range = { start = { line = 3, character = 8 }, ["end"] = { line = 3, character = 15 } },
				},
			})
		elseif method == "textDocument/rename" then
			rename_request = { method = method, params = params }
			callback(nil, { changes = {} })
		else
			callback(nil, { placeholder = "message" })
		end
	end,
}
vim.lsp.get_clients = function(opts)
	if opts and opts.name == "jdtls" then
		return { client }
	end
	if opts and opts.name == "kotlin_lsp" then
		return { kotlin_client }
	end
	return {}
end
client.request = function(_, method, params, callback)
	resolve_request = { method = method, params = params }
	callback(nil, {
		uri = vim.uri_from_fname(kotlin_file),
		range = { start = { line = 3, character = 8 }, ["end"] = { line = 3, character = 15 } },
	})
end
vim.lsp.buf_request_all = function()
	error("kross should use kotlin_lsp for translated references")
end
references_list = nil
kross.references({
	on_list = function(list)
		references_list = list
	end,
})
vim.wait(1000, function()
	return references_list ~= nil
end)
assert(kotlin_client_request, "kross references delegates translated Kotlin source to kotlin_lsp")
assert(kotlin_client_request.params.textDocument.uri == vim.uri_from_fname(kotlin_file), "kotlin_lsp references uses Kotlin source URI")
assert(kotlin_client_request.params.position.line == 3, "kotlin_lsp references uses Kotlin source position")

local original_apply_workspace_edit = vim.lsp.util.apply_workspace_edit
vim.lsp.util.apply_workspace_edit = function(edit, encoding)
	edit_applied = { edit = edit, encoding = encoding }
end
kross.rename("renamedMessage")
vim.wait(1000, function()
	return edit_applied ~= nil
end)
assert(rename_request, "kross rename delegates translated Kotlin source to kotlin_lsp")
assert(rename_request.params.newName == "renamedMessage", "kross rename passes the requested name")
assert(rename_request.params.position.line == 3, "kross rename uses Kotlin source position")
assert(edit_applied.encoding == "utf-16", "kross rename applies edits with kotlin_lsp encoding")

local fallback_called
vim.lsp.get_clients = function(opts)
	if opts and opts.name == "jdtls" then
		return { client }
	end
	return {}
end
kross.rename("fallbackName", {
	fallback = function(name)
		fallback_called = name
	end,
})
vim.wait(1000, function()
	return fallback_called ~= nil
end)
assert(fallback_called == "fallbackName", "kross rename falls back when kotlin_lsp is unavailable")
vim.lsp.util.apply_workspace_edit = original_apply_workspace_edit
vim.lsp.buf_request_all = original_buf_request_all

vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.fn.jobstart = original_jobstart

assert(started, "watcher builds Kotlin buffers that are not attached to jdtls")
assert(started.cwd == root, "unattached Kotlin buffer watcher uses containing jdtls root")
