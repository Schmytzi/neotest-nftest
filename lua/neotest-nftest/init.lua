local lib = require("neotest.lib")
local filetype = require("plenary.filetype")
local DEFAULT_CONFIG = require("neotest-nftest.config")
local registered = false

---Add filetype association for .nf.test files to be recognized as groovy for treesitter parsing
function AddNfTestFiletype()
  filetype.add_table({
    extension = {
      ["nf.test"] = "groovy",
    },
  })
end

---Process test results for a single test case
---@param xml table
---@param result neotest.StrategyResult
---@return neotest.Result
local function parse_test_result(xml, result)
	if xml["_attr"]["status"] == "PASSED" then
		return {
			status = "passed",
			short = "",
			errors = "",
			output = result.output,
		}
	else
		return {
			status = "failed",
			short = xml["failure"]["_attr"]["message"],
			errors = xml["failure"][1],
			output = result.output,
		}
	end
end

---Process test results for a namespace (test suite)
---@param xml table
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
local function parse_namespace_result(xml, result, tree)
	local results = {}
	local names_to_ids = {}
	for _, child in tree:iter() do
		names_to_ids[child.name] = child.id
	end
	for _, test in ipairs(xml["testcase"]) do
		local test_result = parse_test_result(test, result)
		results[names_to_ids[test["_attr"]["name"]]] = test_result
	end
	return results
end

local function parse_directory_result(xml, result, tree)
	local results = {}
	for _, testsuite in ipairs(xml["testsuite"]) do
		local suite_results = parse_namespace_result(testsuite, result, tree)
		for id, test_result in pairs(suite_results) do
			results[id] = test_result
		end
	end
	return results
end

---@class neotestNftest.RunArgs : neotest.RunArgs
---@field profile? string

---@class neotestNftest.NftestAdapter : neotest.Adapter
---@field config neotestNfTest.Config

---Find the project root directory given a file path
---@param path string
---@return string|nil
local function root(path)
  if not registered and lib.subprocess.enabled() then
    lib.subprocess.call('require("neotest-nftest").add_filetype')
    registered = true
  end
	return lib.files.match_root_pattern("nextflow.config", ".git")(path)
end

---Filter files that this adapter can handle
---@param name string Name or path of a file
---@param rel_path string Path to file, relative to root
---@param root string Root directory of project
---@return boolean
local function is_test_file(name, rel_path, root)
	return name:find("%.nf%.test$") ~= nil
end

---Given a file path, parse all the tests within it
---@param file_path string Absolute file path
---@return neotest.Tree|nil
local function discover_positions(file_path)
	local _, data = lib.process.run(
		{ "nf-test", "list", "--silent", "--format", "raw", file_path },
		{ stdout = true, stderr = true }
	)
	local output = vim.gsplit(data.stdout, "\n")

	---@type table<integer, string>
	local test_hashes = {} --- table
	-- filter output table by regex
	for line in output do
		if line:find("@") ~= nil then
			table.insert(test_hashes, line)
		end
	end

  -- test suite definition should be a top-level juxt_function_call
  -- sometimes, the groovy parser gets confused and parses the test suite as identifier + closure
	local query = [[
    (source_file
      (juxt_function_call
        args: (argument_list
          (closure
            (juxt_function_call
              function: (identifier) @funcname
              args: (argument_list (string (string_content) @namespace.name))
              (#eq? @funcname "name")
            ) 
          )
        )
      ) @namespace.definition
    )

    (source_file
      (closure
        (juxt_function_call
          function: (identifier) @funcname
          args: (argument_list (string (string_content) @namespace.name))
          (#eq? @funcname "name")
        ) 
      ) @namespace.definition
    )

    (function_call
      function: (identifier) @funcname
      args: (argument_list
              (string
                (string_content) @test.name
              )
              (closure)
            )
      (#eq? @funcname "test")
    ) @test.definition

  ]]
	-- Calling the internal function to parse positions using treesitter to make our custom lang association work.
	---@type neotest.Tree
	local positions = lib.treesitter.parse_positions(file_path, query, {
		nested_tests = false,
		require_namespaces = true,
	})

	---@type table<integer, neotest.Position>
	local sorted_tests = {}
	for _, position in positions:iter() do
		if position.type == "test" then
			table.insert(sorted_tests, position)
		end
	end
	table.sort(sorted_tests, function(a, b)
		return a.range[1] < b.range[1]
	end) -- sort by line number
	for i, test in ipairs(sorted_tests) do
		test.id = test_hashes[i]
	end
	return positions
end

---Generate build_spec methord
---@param config neotestNfTest.Config
---@return function(args: neotestNftest.RunArgs): neotest.RunSpec
local function make_build_spec(config)

  ---@param args neotestNftest.RunArgs
  ---@return neotest.RunSpec|nil
  return function(args)
    local position = args.tree:data()
    local results_path = vim.fn.tempname()

    local test_arg = position.id
    if position.type == "namespace" then
      test_arg = string.gsub(position.type, "/.+$", "")
    end

    local verbose_flag = ""
    if args.strategy == "dap" then
      verbose_flag = "--verbose"
    end

    local command = {
      "nf-test",
      "test",
      "--ci",
      "--profile",
      "+" .. (args.profile or config.profile),
      "--junitxml",
      results_path,
      verbose_flag,
      args.extra_args or config.extra_args,
      test_arg,
    }

    return {
      command = vim.iter(command):flatten():totable(),
      context = {
        results_path = results_path,
        file = position.path,
        name = position.name,
        id = position.id,
      },
    }
  end
end

---Process test results
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
local function results(spec, result, tree)
	local test_results = {}
	local xml = lib.xml.parse(lib.files.read(spec.context.results_path))
	local position = tree:data()
	if position.type == "test" then
		local test_result = xml["testsuites"]["testsuite"]["testcase"]
		test_results[position.id] = parse_test_result(test_result, result)
	elseif position.type == "namespace" or position.type == "file" then
		-- namespaces and files are equivalent in nf-test
		test_results = parse_namespace_result(xml["testsuites"]["testsuite"], result, tree)
	else
		test_results = parse_directory_result(xml["testsuites"], result, tree)
	end
	return test_results
end

---@param config neotestNfTest.Config
---@return neotestNftest.NftestAdapter
function NftestAdapter(config)
  return {
    name = "neotest-nftest",
    root = root,
    is_test_file = is_test_file,
    discover_positions = discover_positions,
    build_spec = make_build_spec(config),
    results = results,
    config = config,
    add_filetype = AddNfTestFiletype,
  }
end

local adapter = NftestAdapter(DEFAULT_CONFIG)

setmetatable(adapter,{
  __call = function(_, config)
    local user_opts = vim.tbl_extend("force", DEFAULT_CONFIG, config or {})
    return NftestAdapter(user_opts)
  end,
})

if lib.subprocess.enabled() then
  lib.subprocess.call('require("neotest-nftest").add_filetype')
  registered = true
end

return adapter
