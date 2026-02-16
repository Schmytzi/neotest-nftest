local lib = require("neotest.lib")
local filetype = require("plenary.filetype")

filetype.add_table({
  extension = {
    ["nf.test"] = "groovy",
  },
})

---@class neotest.Adapter
---@field name string
local NeotestNftest = { name = "neotest-nftest" }

---Find the project root directory given a file path
---@param path string
---@return string|nil
function NeotestNftest.root(path)
  return lib.files.match_root_pattern("nextflow.config", ".git")(path)
end

---Filter files that this adapter can handle
---@param name string Name or path of a file
---@param rel_path string Path to file, relative to root
---@param root string Root directory of project
---@return boolean
function NeotestNftest.is_test_file(name, rel_path, root)
  return name:find("%.nf%.test$") ~= nil
end

---Given a file path, parse all the tests within it
---@param file_path string Absolute file path
---@return neotest.Tree|nil
function NeotestNftest.discover_positions(file_path)
  local _, data = lib.process.run({"nf-test", "list", "--silent", "--format", "raw", file_path}, {stdout = true, stderr = true})
  local output = vim.gsplit(data.stdout, '\n')

  ---@type table<integer, string>
  local test_hashes = {} --- table
  -- filter output table by regex
  for line in output do
    if line:find('@') ~= nil then
      table.insert(test_hashes, line)
    end
  end

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
  local positions = lib.treesitter._parse_positions(file_path, query, {
    nested_tests = false,
    require_namespaces = true,
  })

  ---@type table<integer, neotest.Position>
  local sorted_tests = {}
  for _, position in positions:iter() do
    if position.type == "test" then table.insert(sorted_tests, position) end
  end
  table.sort(sorted_tests, function(a, b) return a.range[1] < b.range[1] end) -- sort by line number
  for i, test in ipairs(sorted_tests) do
    test.id = test_hashes[i]
  end
  return positions

end

---Build the command to run tests
---@param args neotest.RunArgs
---@return neotest.RunSpec|nil
function NeotestNftest.build_spec(args)
  local position = args.tree:data()
  local results_path = vim.fn.tempname()

  local test_arg = position.id
  if position.type == "namespace" then
    test_arg = string.gsub(position.type, "/.+$", "")
  end

  print(results_path)
  local command = {
    "nf-test",
    "test",
    "--ci",
    "--profile", "+docker",
    "--junitxml", results_path,
    test_arg,
  }

  return {
    command = command,
    context = {
      results_path = results_path,
      file = position.path,
      name = position.name,
      id = position.id,
    }
  }
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
      errors = xml["failure"][1],
      output = result.output,
    }
  else
    return {
      status = "failed",
      short = xml["failure"]["_attr"]["message"],
      errors = xml["failure"],
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
  for child in tree:children() do
    names_to_ids[child:data().name] = child:data().id
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

---Process test results
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function NeotestNftest.results(spec, result, tree)
  local results = {}
  local xml = lib.xml.parse(lib.files.read(spec.context.results_path))
  local position = tree:data()
  if position.type == "test" then
    local test_result = xml['testsuites']["testsuite"]["testcase"]
    results[position.id] = parse_test_result(test_result, result)
  elseif position.type == "namespace" or position.type == "file" then
    -- namespaces and files are equivalent in nf-test
    results = parse_namespace_result(xml["testsuites"]["testsuite"], result, tree)
  else
    results = parse_directory_result(xml["testsuites"], result, tree)
  end
  return results
end


return NeotestNftest
