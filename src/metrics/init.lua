-------------------------------------------------------------------------------
-- Interface for metrics module
-- @release 2011/05/04, Ivan Simko
-- @release 2013/04/04, Peter Kosa
-------------------------------------------------------------------------------

local lpeg = require 'lpeg'
local parser  = require 'leg.parser'
local grammar = require 'leg.grammar'
	
local rules = require 'metrics.rules'
local utils = require 'metrics.utils'

local math = require 'math'

local io, table, pairs, type, print = io, table, pairs, type, print 

local AST_capt = require 'metrics.captures.AST'
local LOC_capt = require 'metrics.captures.LOC'
local ldoc_capt = require 'metrics.luadoc.captures'
local block_capt = require 'metrics.captures.block'
local infoflow_capt = require 'metrics.captures.infoflow'
local halstead_capt = require 'metrics.captures.halstead'
local ftree_capt = require 'metrics.captures.functiontree'
local stats_capt = require 'metrics.captures.statements'
local cyclo_capt = require 'metrics.captures.cyclomatic'
local document_metrics = require 'metrics.captures.document_metrics'

module ("metrics")

-- needed to set higher because of back-tracking patterns
lpeg.setmaxstack (400)

local capture_table = {}

grammar.pipe(LOC_capt.captures, AST_capt.captures)
grammar.pipe(block_capt.captures, LOC_capt.captures)
grammar.pipe(infoflow_capt.captures, block_capt.captures)
grammar.pipe(halstead_capt.captures, infoflow_capt.captures)
grammar.pipe(ftree_capt.captures, halstead_capt.captures)
grammar.pipe(ldoc_capt.captures, ftree_capt.captures)
grammar.pipe(stats_capt.captures,ldoc_capt.captures)
grammar.pipe(cyclo_capt.captures, stats_capt.captures)
grammar.pipe(document_metrics.captures,cyclo_capt.captures)
grammar.pipe(capture_table,document_metrics.captures)

local lua = lpeg.P(grammar.apply(parser.rules, rules.rules, capture_table))
local patt = lua / function(...) 
	return {...} 
end

------------------------------------------------------------------------
-- Main function for source code analysis
-- returns an AST with included metric values in each node
-- @name processText
-- @param code - string containing the source code to be analyzed
function processText(code)
	
	local result = patt:match(code)[1]
	
	return result
end

------------------------------------------------------------------------
-- Function to join metrics from different AST's
-- returns an AST with joined metrics, where possible
-- @name doGlobalMetrics
-- @param file_metricsAST_list table of AST's' generated by function processText
function doGlobalMetrics(file_metricsAST_list)
	
	-- keep AST lists
	local returnObject = {}
	returnObject.file_AST_list = file_metricsAST_list
	
	--- function declarations
	local total_function_definitions = {}

	local anonymouscounter=0   -- for naming anonymous functions
	local anonymouscounterT = 0 -- for naming anonymous  tables
	for filename, AST in pairs(file_metricsAST_list) do
		for _, fun in pairs(AST.metrics.blockdata.fundefs) do

			-- edit to suit luadoc expectations
			if (fun.tag == 'GlobalFunction' or fun.tag == 'LocalFunction' or fun.tag == 'Function') then
-- anonymous function type
				if(fun.name=="#anonymous#")then
					anonymouscounter=anonymouscounter+1
					fun.name = fun.name .. anonymouscounter
					fun.path = filename
				elseif(fun.name:match("[%.%[]") or fun.isGlobal==nil)then
-- table-field function type
					fun.fcntype = 'table-field'
				elseif (fun.isGlobal) then fun.fcntype = 'global' else fun.fcntype = 'local' end
					fun.path = filename
					table.insert(total_function_definitions, fun)
			end	
		end
	end
	table.sort(total_function_definitions, utils.compare_functions_by_name)				
	returnObject.functionDefinitions = total_function_definitions

	
-- ^ `tables` list of tables in files , concatenate luaDoc_tables and docutables	
	local total_table_definitions = {}
	local set = {}
	for filename, AST in pairs(file_metricsAST_list) do

	-- concatenate two tables by  Exp node tables
		
		for k,tabl in pairs(AST.luaDoc_tables) do
			tabl.path=filename		
			tabl.name = k
			table.insert(total_table_definitions, tabl)
			set[tabl] = true
		end					
		for k,tabl in pairs(AST.metrics.docutables) do
			if(tabl.ttype=="anonymous")then
				anonymouscounterT=anonymouscounterT+1
			 	tabl.name = tabl.name .. anonymouscounterT
			end
			if (not tabl.Expnode) then
			 	tabl.path = filename	
				table.insert(total_table_definitions, tabl)
			elseif(set[tabl.Expnode]~=true)then
				tabl.path = filename	
				table.insert(total_table_definitions, tabl)
				set[tabl.Expnode] = true
			end		
		end
 	end	
	returnObject.tables = total_table_definitions
			
	
	
	-- merge number of lines metrics
	returnObject.LOC = {}
	
	for filename, AST in pairs(file_metricsAST_list) do
	
		for name, count in pairs(AST.metrics.LOC) do
			if not returnObject.LOC[name] then returnObject.LOC[name] = 0 end
			returnObject.LOC[name] = returnObject.LOC[name] + count
		end
	
	end	
	-- combine halstead metrics
	
	local operators, operands = {}, {}
	
	for filename, AST in pairs(file_metricsAST_list) do
		for name, count in pairs(AST.metrics.halstead.operators) do
			if (operators[name] == nil) then 
				operators[name] = count
			else
				operators[name] = operators[name] + count
			end
		end
		for name, count in pairs(AST.metrics.halstead.operands) do
			if (operands[name] == nil) then 
				operands[name] = count
			else
				operands[name] = operands[name] + count
			end
		end
	end
	
	local number_of_operators = 0
	local unique_operators = 0
	for op, count in pairs(operators) do 
		unique_operators = unique_operators + 1
		number_of_operators = number_of_operators + count
	end
	
	local number_of_operands = 0
	local unique_operands = 0
	for op, count in pairs(operands) do 
		unique_operands = unique_operands + 1
		number_of_operands = number_of_operands + count
	end
	
	returnObject.halstead = {}
	
	halstead_capt.calculateHalstead(returnObject.halstead, operators, operands)
	
	-- instability metric for each module
	-- 		afferent and efferent coupling --- instability metric
	-- 		afferent - connection to other modules
	-- 		efferent - connetions from other modules
	
	for currentFilename, currentAST in pairs(file_metricsAST_list) do
	
		currentAST.metrics.coupling = {}
		currentAST.metrics.coupling.afferent_coupling = 0
		currentAST.metrics.coupling.efferent_coupling = 0
		
		local currentName = currentAST.metrics.currentModuleName or filename
		
		for name in pairs(currentAST.metrics.moduleCalls) do 
			currentAST.metrics.coupling.afferent_coupling = currentAST.metrics.coupling.afferent_coupling + 1
		end
		
		for filename, AST in pairs(file_metricsAST_list) do
			if (filename ~= currentFilename) then
				if (AST.metrics.moduleCalls[currentName]) then currentAST.metrics.coupling.efferent_coupling = currentAST.metrics.coupling.efferent_coupling + 1 end
			end
		end
		
		currentAST.metrics.coupling.instability = currentAST.metrics.coupling.afferent_coupling / (currentAST.metrics.coupling.efferent_coupling + currentAST.metrics.coupling.afferent_coupling)
		
	end
	
	-- statement metrics
	
	returnObject.statements = {}
	
	for filename, AST in pairs(file_metricsAST_list) do
	
		for name, stats in pairs(AST.metrics.statements) do
			if not returnObject.statements[name] then returnObject.statements[name] = {} end
			for _, stat in pairs(stats) do
				table.insert(returnObject.statements[name], stat)
			end
		end
	
	end	
	
	-- merge moduleDefinitions
	returnObject.moduleDefinitions = {}
	
	for filename, AST in pairs(file_metricsAST_list) do
		for exec, moduleRef in pairs(AST.metrics.moduleDefinitions) do
			if (moduleRef.moduleName) then 
				table.insert(returnObject.moduleDefinitions, moduleRef)
			end
		end

	end


	--merge document metrics
	returnObject.documentMetrics={}
	for filename, AST in pairs(file_metricsAST_list) do
		for name, count in pairs(AST.metrics.documentMetrics) do		
			if( type(count)=="table")then
				if not returnObject.documentMetrics[name] then returnObject.documentMetrics[name]={} end
				for _,v in pairs(count) do	
					table.insert(returnObject.documentMetrics[name],v)
				end		
			else 	
				if not returnObject.documentMetrics[name] then returnObject.documentMetrics[name] = 0 end
				returnObject.documentMetrics[name]=returnObject.documentMetrics[name]+count
			end		
		end
	end		

	return returnObject
end
