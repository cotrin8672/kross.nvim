local M = {}

local defaults = {
	watch = true,
	build_on_attach = false,
	build_args = { "classes" },
	plugin_auto_build = true,
	plugin_build_args = { "jar", "--no-daemon" },
	debounce_ms = 300,
	notify = true,
}

local state = {
	config = vim.deepcopy(defaults),
	roots = {},
	timers = {},
	running = {},
	attach_retries = {},
}

local uv = vim.uv or vim.loop
local group = vim.api.nvim_create_augroup("kross", { clear = true })

local function notify(message, level)
	if state.config.notify then
		vim.notify(message, level or vim.log.levels.INFO)
	end
end

local function root_key(root)
	return vim.fs.normalize(root)
end

local function output_dir(root)
	return vim.fs.normalize(root .. "/build/classes/kotlin/main")
end

local function output_attached(root)
	local classpath = root_key(root .. "/.classpath")
	if vim.fn.filereadable(classpath) ~= 1 then
		return false
	end
	return table.concat(vim.fn.readfile(classpath), "\n"):find(output_dir(root), 1, true) ~= nil
end

local function build_command(root)
	if state.config.build_command then
		return state.config.build_command
	end

	local wrapper = root .. (vim.fn.has("win32") == 1 and "/gradlew.bat" or "/gradlew")
	if vim.fn.filereadable(wrapper) == 1 then
		return wrapper
	end

	return "gradle"
end

local function root_for_buf(bufnr)
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls" })) do
		if client.config and client.config.root_dir then
			return client.config.root_dir
		end
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end

	path = root_key(path)
	for _, client in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
		local root = client.config and client.config.root_dir
		if root then
			root = root_key(root)
			if path == root or vim.startswith(path, root .. "/") then
				return root
			end
		end
	end

	return nil
end

local function attach_root(root)
	local output = output_dir(root)
	if vim.fn.isdirectory(output) ~= 1 then
		return false
	end

	for _, client in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
		if client.config and root_key(client.config.root_dir) == root_key(root) then
			M.attach(client)
			return true
		end
	end

	return false
end

local function plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function plugin_build_command(root)
	if state.config.plugin_build_command then
		return state.config.plugin_build_command
	end

	local wrapper = root .. (vim.fn.has("win32") == 1 and "/gradlew.bat" or "/gradlew")
	if vim.fn.filereadable(wrapper) == 1 then
		return wrapper
	end

	return "gradle"
end

local function plugin_jar(root)
	local jars = vim.fn.globpath(root, "build/libs/kross-jdtls-*.jar", false, true)
	table.sort(jars, function(a, b)
		local a_mtime, b_mtime = vim.fn.getftime(a), vim.fn.getftime(b)
		return a_mtime == b_mtime and a > b or a_mtime > b_mtime
	end)
	return jars[1]
end

local function latest_plugin_source_mtime(root)
	local latest = 0
	for _, pattern in ipairs({ "src/main/**/*", "build.gradle*", "settings.gradle*", "gradle.properties" }) do
		for _, path in ipairs(vim.fn.globpath(root, pattern, false, true)) do
			latest = math.max(latest, vim.fn.getftime(path))
		end
	end
	return latest
end

local function plugin_jar_stale(root, jar)
	if not jar or vim.fn.filereadable(jar) ~= 1 then
		return true
	end

	local jar_mtime = vim.fn.getftime(jar)
	return jar_mtime <= 0 or latest_plugin_source_mtime(root) > jar_mtime
end

local function plugin_build_args(root)
	local command = plugin_build_command(root)
	local args = type(command) == "table" and vim.deepcopy(command) or { command }
	return vim.list_extend(args, state.config.plugin_build_args or {})
end

local function build_plugin_jar(root)
	local args = plugin_build_args(root)
	notify("kross: building JDT LS bundle")

	local result
	if vim.system then
		result = vim.system(args, { cwd = root, text = true }):wait()
	else
		local cwd = uv.cwd()
		uv.chdir(root)
		local output = vim.fn.system(args)
		result = { code = vim.v.shell_error, stdout = output, stderr = "" }
		uv.chdir(cwd)
	end

	if result.code == 0 then
		return true
	end

	local output = vim.trim(table.concat({ result.stderr or "", result.stdout or "" }, "\n"))
	if output ~= "" then
		output = "\n" .. output
	end
	vim.notify("kross: failed to build JDT LS bundle with exit code " .. result.code .. output, vim.log.levels.ERROR)
	return false
end

local function schedule_attach_retry(client, attempts)
	local root = client and client.config and client.config.root_dir
	if not root or attempts <= 0 then
		return
	end

	root = root_key(root)
	state.attach_retries[root] = (state.attach_retries[root] or 0) + 1
	local token = state.attach_retries[root]
	vim.defer_fn(function()
		if state.attach_retries[root] ~= token then
			return
		end
		M.attach(client, attempts - 1)
	end, 3000)
end

local function show_locations(locations, client, opts)
	opts = opts or {}
	if opts.on_list then
		opts.on_list({
			title = "LSP locations",
			items = vim.lsp.util.locations_to_items(locations, client.offset_encoding),
			context = { bufnr = vim.api.nvim_get_current_buf(), method = "textDocument/definition" },
		})
		return
	end

	if #locations == 1 then
		vim.lsp.util.show_document(locations[1], client.offset_encoding, { focus = true, reuse_win = opts.reuse_win })
		return
	end

	local list = {
		title = "LSP locations",
		items = vim.lsp.util.locations_to_items(locations, client.offset_encoding),
		context = { bufnr = vim.api.nvim_get_current_buf(), method = "textDocument/definition" },
	}
	if opts.loclist then
		vim.fn.setloclist(0, {}, " ", list)
		vim.cmd.lopen()
	else
		vim.fn.setqflist({}, " ", list)
		vim.cmd("botright copen")
	end
end

local function definition_locations(result)
	if not result then
		return {}
	end
	if result.uri or result.targetUri then
		return { result }
	end
	return vim.islist(result) and result or {}
end

function M.definition(opts)
	opts = opts or {}
	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "jdtls", method = "textDocument/definition" })
	if not next(clients) then
		return vim.lsp.buf.definition(opts)
	end

	local first_client = clients[1]
	local position_params = vim.lsp.util.make_position_params(win, first_client.offset_encoding)
	local function standard_definition()
		vim.lsp.buf_request_all(bufnr, "textDocument/definition", function(client)
			return vim.lsp.util.make_position_params(win, client.offset_encoding)
		end, function(results)
			local locations = {}
			local response_client = first_client
			for client_id, response in pairs(results) do
				response_client = vim.lsp.get_client_by_id(client_id) or response_client
				vim.list_extend(locations, definition_locations(response and response.result))
			end
			if not next(locations) then
				vim.notify("No locations found", vim.log.levels.INFO)
				return
			end
			show_locations(locations, response_client, opts)
		end)
	end

	first_client:request("workspace/executeCommand", {
		command = "kotlin.java.resolveKotlinSource",
		arguments = {
			{
				textDocumentUri = position_params.textDocument.uri,
				position = position_params.position,
			},
		},
	}, function(err, location)
		if err or not location then
			standard_definition()
			return
		end
		show_locations({ location }, first_client, opts)
	end, bufnr)
end

local function map_navigation(bufnr, client)
	if not client or client.name ~= "jdtls" then
		return
	end

	vim.schedule(function()
		vim.keymap.set("n", "gd", function()
			return M.definition()
		end, { buffer = bufnr, silent = true, desc = "kross Kotlin definition" })
		vim.keymap.set("n", "gr", function()
			return vim.lsp.buf.references()
		end, { buffer = bufnr, silent = true, desc = "kross Kotlin references" })
		vim.keymap.set("n", "grr", function()
			return vim.lsp.buf.references()
		end, { buffer = bufnr, silent = true, desc = "kross Kotlin references" })
	end)
end

function M.jar()
	local root = plugin_root()
	local jar = plugin_jar(root)
	if state.config.plugin_auto_build ~= false and plugin_jar_stale(root, jar) and not build_plugin_jar(root) then
		return nil
	end

	return plugin_jar(root)
end

function M.bundles(jar)
	if not jar then
		jar = M.jar()
	end
	if jar and vim.fn.filereadable(jar) == 1 then
		return { jar }
	end

	return {}
end

function M.build(root)
	root = root or root_for_buf(0) or uv.cwd()
	if not root then
		return
	end

	root = root_key(root)
	if state.running[root] then
		return
	end

	local command = build_command(root)
	local args = vim.list_extend({ command }, state.config.build_args or {})
	state.running[root] = true
	notify("kross: building " .. root)

	local job = vim.fn.jobstart(args, {
		cwd = root,
		stdout_buffered = true,
		stderr_buffered = true,
		on_exit = function(_, code)
			state.running[root] = nil
			vim.schedule(function()
				if code == 0 then
					attach_root(root)
					notify("kross: build finished")
				else
					vim.notify("kross: build failed with exit code " .. code, vim.log.levels.ERROR)
				end
			end)
		end,
	})
	if job <= 0 then
		state.running[root] = nil
		vim.notify("kross: failed to start build command: " .. command, vim.log.levels.ERROR)
	end
end

function M.schedule_build(root)
	root = root_key(root)
	if state.timers[root] then
		state.timers[root]:stop()
	else
		state.timers[root] = uv.new_timer()
	end

	state.timers[root]:start(state.config.debounce_ms, 0, function()
		vim.schedule(function()
			M.build(root)
		end)
	end)
end

function M.watch(root)
	if not root then
		return
	end

	state.roots[root_key(root)] = true
end

function M.unwatch(root)
	if root then
		state.roots[root_key(root)] = nil
	else
		state.roots = {}
	end
end

function M.attach(client, retry_attempts)
	if not client or client.name ~= "jdtls" then
		return
	end

	local root = client.config and client.config.root_dir
	if not root then
		return
	end

	if state.config.watch then
		M.watch(root)
	end

	if state.config.build_on_attach then
		M.build(root)
	end

	local output = output_dir(root)
	if vim.fn.isdirectory(output) ~= 1 then
		return
	end

	local already_attached = output_attached(root)
	client:request("workspace/executeCommand", {
		command = "kotlin.java.setKotlinBuildOutput",
		arguments = { output },
	}, function(err)
		if err then
			vim.notify("kross: failed to attach Kotlin output: " .. tostring(err.message or err), vim.log.levels.WARN)
		end
	end)

	if not already_attached then
		schedule_attach_retry(client, retry_attempts or 5)
	end
end

function M.setup(opts)
	state.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

	vim.api.nvim_clear_autocmds({ group = group })
	vim.api.nvim_create_autocmd("LspAttach", {
		group = group,
		callback = function(args)
			local client = vim.lsp.get_client_by_id(args.data.client_id)
			M.attach(client)
			map_navigation(args.buf, client)
		end,
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "*.kt", "*.kts" },
		callback = function(args)
			local root = root_for_buf(args.buf)
			if root and state.roots[root_key(root)] then
				M.schedule_build(root)
			end
		end,
	})

	vim.api.nvim_create_user_command("KrossBuild", function()
		M.build()
	end, { force = true })
	vim.api.nvim_create_user_command("KrossWatchStart", function()
		M.watch(root_for_buf(0) or uv.cwd())
	end, { force = true })
	vim.api.nvim_create_user_command("KrossWatchStop", function()
		M.unwatch(root_for_buf(0))
	end, { force = true })
end

return M
