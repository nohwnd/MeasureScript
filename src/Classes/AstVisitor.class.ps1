using namespace System.Collections.Generic
using namespace System.Management.Automation.Language

#region ProfilingAstVisitor
class ProfilingAstVisitor : ICustomAstVisitor
{
    [Profiler]$Profiler = $null
    ProfilingAstVisitor([Profiler]$profiler) {
        $this.Profiler = $profiler
    }
    [Object] VisitElement([object]$element) {
        if ($element -eq $null) {
            return $null
        }
        $res = $element.Visit($this)
        return $res
    }
    [Object] VisitElements([Object]$elements) {
            if ($elements -eq $null -or $elements.Count -eq 0)
            {
                return $null
            }
            $typeName = $elements.gettype().GenericTypeArguments.Fullname

            $newElements = New-Object -TypeName "System.Collections.Generic.List[$typeName]"
            foreach($element in $elements) {
                $visitedResult = $element.Visit($this)
                $newElements.add($visitedResult)
            }
            return $newElements
    }
    [StatementAst[]] VisitStatements([object]$Statements)
    {
            $newStatements = [List[StatementAst]]::new()
            foreach ($statement in $statements)
            {
                [bool]$instrument = $statement -is [PipelineBaseAst]
                $extent = $statement.Extent
                if ($instrument)
                {
                    $expressionAstCollection = [List[ExpressionAst]]::new()
                    $constantExpression = [ConstantExpressionAst]::new($extent, $extent.StartLineNumber - 1)
                    $expressionAstCollection.Add($constantExpression)
                    $constantProfiler = [ConstantExpressionAst]::new($extent, $this.Profiler)
                    $constantStartline = [StringConstantExpressionAst]::new($extent, "StartLine", [StringConstantType]::BareWord)
                    $invokeMember = [InvokeMemberExpressionAst]::new(
                            $extent,
                            $constantProfiler,
                            $constantStartline,
                            $expressionAstCollection,
                            $false
                        )
                    $startLine = [CommandExpressionAst]::new(
                        $extent,
                        $invokeMember,
                        $null
                    )
                    $pipe = [PipelineAst]::new($extent, $startLine);
                    $newStatements.Add($pipe)
                }
                $newStatements.Add($this.VisitElement($statement))
                if ($instrument)
                {
                    $expressionAstCollection = [List[ExpressionAst]]::new()
                    $expressionAstCollection.Add([ConstantExpressionAst]::new($extent, $extent.StartLineNumber - 1))
                    $endLine = [CommandExpressionAst]::new(
                        $extent,
                        [InvokeMemberExpressionAst]::new(
                            $extent,
                            [ConstantExpressionAst]::new($extent, $this.Profiler),
                            [StringConstantExpressionAst]::new($extent, "EndLine", [StringConstantType]::BareWord),
                            $expressionAstCollection,
                            $false
                        ),
                        $null
                    )
                    $pipe = [PipelineAst]::new($extent, $endLine)
                    $newStatements.add($pipe)
                }
            }
            return $newStatements
        }

    [object] VisitScriptBlock([ScriptBlockAst] $scriptBlockAst)
    {
        $newParamBlock = $this.VisitElement($scriptBlockAst.ParamBlock)
        $newBeginBlock = $this.VisitElement($scriptBlockAst.BeginBlock)
        $newProcessBlock = $this.VisitElement($scriptBlockAst.ProcessBlock)
        $newEndBlock = $this.VisitElement($scriptBlockAst.EndBlock)
        $newDynamicParamBlock = $this.VisitElement($scriptBlockAst.DynamicParamBlock)
        return [ScriptBlockAst]::new($scriptBlockAst.Extent, $newParamBlock, $newBeginBlock, $newProcessBlock, $newEndBlock, $newDynamicParamBlock)
    }


    [object] VisitNamedBlock([NamedBlockAst] $namedBlockAst)
    {
        $newTraps = $this.VisitElements($namedBlockAst.Traps)
        $newStatements = $this.VisitStatements($namedBlockAst.Statements)
        $statementBlock = [StatementBlockAst]::new($namedBlockAst.Extent,$newStatements,$newTraps)
        return [NamedBlockAst]::new($namedBlockAst.Extent, $namedBlockAst.BlockKind, $statementBlock, $namedBlockAst.Unnamed)
    }

    [object] VisitFunctionDefinition([FunctionDefinitionAst] $functionDefinitionAst)
    {
        $newBody = $this.VisitElement($functionDefinitionAst.Body)
        return [FunctionDefinitionAst]::new($functionDefinitionAst.Extent, $functionDefinitionAst.IsFilter,$functionDefinitionAst.IsWorkflow, $functionDefinitionAst.Name, $this.VisitElements($functionDefinitionAst.Parameters), $newBody);
    }

    [object] VisitStatementBlock([StatementBlockAst] $statementBlockAst)
    {
        $newStatements = $this.VisitStatements($statementBlockAst.Statements)
        $newTraps = $this.VisitElements($statementBlockAst.Traps)
        $traps = if ($newTraps) { $newTraps } else { if ($statementBlockAst.Traps) { $statementBlockAst.Traps } else {  [System.Collections.Generic.List[System.Management.Automation.Language.TrapStatementAst]]@() } }
        return [StatementBlockAst]::new($statementBlockAst.Extent, $newStatements, $traps)
    }

    [object] VisitIfStatement([IfStatementAst] $ifStmtAst)
    {
        [Tuple[PipelineBaseAst,StatementBlockAst][]]$newClauses = @(foreach($clause in $ifStmtAst.Clauses){
            $newClauseTest = [PipelineBaseAst]$this.VisitElement($clause.Item1)
            $newStatementBlock = [StatementBlockAst]$this.VisitElement($clause.Item2)
            [Tuple[PipelineBaseAst,StatementBlockAst]]::new($newClauseTest,$newStatementBlock)
        })
        $newElseClause = $this.VisitElement($ifStmtAst.ElseClause)
        return [IfStatementAst]::new($ifStmtAst.Extent, $newClauses, $newElseClause)
    }

    [object] VisitTrap([TrapStatementAst] $trapStatementAst)
    {
        return [TrapStatementAst]::new($trapStatementAst.Extent, $this.VisitElement($trapStatementAst.TrapType), $this.VisitElement($trapStatementAst.Body))
    }

    [object] VisitSwitchStatement([SwitchStatementAst] $switchStatementAst)
    {
        $newCondition = $this.VisitElement($switchStatementAst.Condition)
        $newClauses = [System.Collections.Generic.List[System.Tuple[System.Management.Automation.Language.ExpressionAst,System.Management.Automation.Language.StatementBlockAst]]]@()
        foreach ($clause in $switchStatementAst.Clauses) {
            $newClauseTest = $this.VisitElement($clause.Item1)
            $newStatementBlock = $this.VisitElement($clause.Item2)
            $newClauses.Add([Tuple[ExpressionAst,StatementBlockAst]]::new($newClauseTest,$newStatementBlock))
        }
        $newDefault = $this.VisitElement($switchStatementAst.Default)
        return [SwitchStatementAst]::new($switchStatementAst.Extent, $switchStatementAst.Label,$newCondition,$switchStatementAst.Flags, $newClauses, $newDefault)
    }

    [object] VisitDataStatement([DataStatementAst] $dataStatementAst)
    {

#         Line |
#    4 |  instrument-script -path /projects/pester/bin/pester.psm1
#      |  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#      | Exception calling "GetScriptBlock" with "0" argument(s): "At line:9692 char:5 +     @{ +     ~~ Method calls are not allowed in restricted
#      | language mode or a Data section.  At line:9727 char:5 +     @{ +     ~~ Method calls are not allowed in restricted language mode or a Data
#      | section."
        return $dataStatementAst.Copy()
        # $newBody = $this.VisitElement($dataStatementAst.Body)
        # $newCommandsAllowed = $this.VisitElements($dataStatementAst.CommandsAllowed)
        # return [DataStatementAst]::new($dataStatementAst.Extent, $dataStatementAst.Variable, $newCommandsAllowed, $newBody)
    }

    [object] VisitForEachStatement([ForEachStatementAst] $forEachStatementAst)
    {
        $newVariable = $this.VisitElement($forEachStatementAst.Variable)
        $newCondition = $this.VisitElement($forEachStatementAst.Condition)
        $newBody = $this.VisitElement($forEachStatementAst.Body)
        return [ForEachStatementAst]::new($forEachStatementAst.Extent, $forEachStatementAst.Label, [ForEachFlags]::None, $newVariable, $newCondition, $newBody)
    }

    [object] VisitDoWhileStatement([DoWhileStatementAst] $doWhileStatementAst)
    {
        $newCondition = $this.VisitElement($doWhileStatementAst.Condition)
        $newBody = $this.VisitElement($doWhileStatementAst.Body)
        return [DoWhileStatementAst]::new($doWhileStatementAst.Extent, $doWhileStatementAst.Label, $newCondition, $newBody)
    }

    [object] VisitForStatement([ForStatementAst] $forStatementAst)
    {
        $newInitializer = $this.VisitElement($forStatementAst.Initializer)
        $newCondition = $this.VisitElement($forStatementAst.Condition)
        $newIterator = $this.VisitElement($forStatementAst.Iterator)
        $newBody = $this.VisitElement($forStatementAst.Body)
        return [ForStatementAst]::new($forStatementAst.Extent, $forStatementAst.Label, $newInitializer, $newCondition, $newIterator, $newBody)
    }

    [object] VisitWhileStatement([WhileStatementAst] $whileStatementAst)
    {
        $newCondition = $this.VisitElement($whileStatementAst.Condition)
        $newBody = $this.VisitElement($whileStatementAst.Body)
        return [WhileStatementAst]::new($whileStatementAst.Extent, $whileStatementAst.Label, $newCondition, $newBody)
    }

    [object] VisitCatchClause([CatchClauseAst] $catchClauseAst)
    {
        $copy = $catchClauseAst.Copy()
        $newBody = $this.VisitElement($copy.Body)
        try {
            return [CatchClauseAst]::new($copy.Extent, $copy.CatchTypes, $newBody)
        }
        catch {
            return $null
        }
    }

    [object] VisitTryStatement([TryStatementAst] $tryStatementAst)
    {
        $copy = $tryStatementAst.Copy()
        $newBody = $this.VisitElement($copy.Body)
        $newCatchClauses = $this.VisitElements($copy.CatchClauses)
        try {
           
            if ($newCatchClauses) {
                if ($newCatchClauses -is [System.Management.Automation.Language.CatchClauseAst]) {
                    # InvalidArgument: Cannot convert the "catch {
                    #     $rootBlock.OwnPassed = $false
                    #     $rootBlock.ErrorRecord.Add($_)
                    # }" value of type "System.Management.Automation.Language.CatchClauseAst" to type "System.Collections.Generic.IEnumerable`1[System.Management.Automation.Language.CatchClauseAst]".
                    [System.Collections.Generic.IEnumerable[System.Management.Automation.Language.CatchClauseAst]] $catchClauses = [System.Collections.Generic.List[System.Management.Automation.Language.CatchClauseAst]]@($newCatchClauses)
                } else {
                    $cs = [System.Collections.Generic.List[System.Management.Automation.Language.CatchClauseAst]]@()
                    foreach ($c in $newCatchClauses) {
                        $cs.Add($c)
                    }
                    # is there an implicit operator for the single items that takes precendence and causes this issue?
                    # MetadataError: C:\Projects\temp\measurescript\src\Classes\AstVisitor.class.ps1:212:21
                    # Line |
                    #  212 |                      $cs
                    #      |                      ~~~
                    #      | Cannot convert the "catch {             $rootBlock.OwnPassed = $false             $rootBlock.ErrorRecord.Add($_)         }" value of type "System.Management.Automation.Language.CatchClauseAst" to type
                    #      | "System.Collections.Generic.IEnumerable`1[System.Management.Automation.Language.CatchClauseAst]".
                    [System.Collections.Generic.IEnumerable[System.Management.Automation.Language.CatchClauseAst]] $catchClauses = [System.Collections.Generic.IEnumerable[System.Management.Automation.Language.CatchClauseAst]]$cs
                }
            }
            else {
                [System.Collections.Generic.IEnumerable[System.Management.Automation.Language.CatchClauseAst]] $catchClauses = $copy.Copy().CatchClauses
            }
            $newFinally = $this.VisitElement($copy.Finally)
            $ast = [TryStatementAst]::new($copy.Extent, $newBody, $catchClauses, $newFinally)
            return $ast
        }
        catch {
            return $copy
        }
    }

    [object] VisitDoUntilStatement([DoUntilStatementAst] $doUntilStatementAst)
    {
        $newCondition = $this.VisitElement($doUntilStatementAst.Condition)
        $newBody = $this.VisitElement($doUntilStatementAst.Body)
        return [DoUntilStatementAst]::new($doUntilStatementAst.Extent, $doUntilStatementAst.Label, $newCondition, $newBody)
    }

    [object] VisitParamBlock([ParamBlockAst] $paramBlockAst)
    {
        $newAttributes = $this.VisitElements($paramBlockAst.Attributes)
        $newParameters = $this.VisitElements($paramBlockAst.Parameters)
        return [ParamBlockAst]::new($paramBlockAst.Extent, $newAttributes, $newParameters)
    }

    [object] VisitErrorStatement([ErrorStatementAst] $errorStatementAst)
    {
        return $errorStatementAst
    }

    [object] VisitErrorExpression([ErrorExpressionAst] $errorExpressionAst)
    {
        return $errorExpressionAst
    }

    [object] VisitTypeConstraint([TypeConstraintAst] $typeConstraintAst)
    {
        return [TypeConstraintAst]::new($typeConstraintAst.Extent, $typeConstraintAst.TypeName)
    }

    [object] VisitAttribute([AttributeAst] $attributeAst)
    {
        $newPositionalArguments = $this.VisitElements($attributeAst.PositionalArguments)
        $newNamedArguments = $this.VisitElements($attributeAst.NamedArguments)
        return [AttributeAst]::new($attributeAst.Extent, $attributeAst.TypeName, $newPositionalArguments, $newNamedArguments)
    }

    [object] VisitNamedAttributeArgument([NamedAttributeArgumentAst] $namedAttributeArgumentAst)
    {
        $newArgument = $this.VisitElement($namedAttributeArgumentAst.Argument)
        return [NamedAttributeArgumentAst]::new($namedAttributeArgumentAst.Extent, $namedAttributeArgumentAst.ArgumentName, $newArgument,$namedAttributeArgumentAst.ExpressionOmitted)
    }

    [object] VisitParameter([ParameterAst] $parameterAst)
    {
        $newName = $this.VisitElement($parameterAst.Name)
        $newAttributes = $this.VisitElements($parameterAst.Attributes)
        $newDefaultValue = $this.VisitElement($parameterAst.DefaultValue)
        return [ParameterAst]::new($parameterAst.Extent, $newName, $newAttributes, $newDefaultValue)
    }

    [object] VisitBreakStatement([BreakStatementAst] $breakStatementAst)
    {
        $newLabel = $this.VisitElement($breakStatementAst.Label)
        return [BreakStatementAst]::new($breakStatementAst.Extent, $newLabel)
    }

    [object] VisitContinueStatement([ContinueStatementAst] $continueStatementAst)
    {
        $newLabel = $this.VisitElement($continueStatementAst.Label)
        return [ContinueStatementAst]::new($continueStatementAst.Extent, $newLabel)
    }

    [object] VisitReturnStatement([ReturnStatementAst] $returnStatementAst)
    {
        $newPipeline = $this.VisitElement($returnStatementAst.Pipeline)
        return [ReturnStatementAst]::new($returnStatementAst.Extent, $newPipeline)
    }

    [object] VisitExitStatement([ExitStatementAst] $exitStatementAst)
    {
        $newPipeline = $this.VisitElement($exitStatementAst.Pipeline)
        return [ExitStatementAst]::new($exitStatementAst.Extent, $newPipeline)
    }

    [object] VisitThrowStatement([ThrowStatementAst] $throwStatementAst)
    {
        $newPipeline = $this.VisitElement($throwStatementAst.Pipeline)
        return [ThrowStatementAst]::new($throwStatementAst.Extent, $newPipeline)
    }

    [object] VisitAssignmentStatement([AssignmentStatementAst] $assignmentStatementAst)
    {
        $newLeft = $this.VisitElement($assignmentStatementAst.Left)
        $newRight = $this.VisitElement($assignmentStatementAst.Right)
        return [AssignmentStatementAst]::new($assignmentStatementAst.Extent, $newLeft, $assignmentStatementAst.Operator,$newRight, $assignmentStatementAst.ErrorPosition)
    }

    [object] VisitPipeline([PipelineAst] $pipelineAst)
    {
        $newPipeElements = $this.VisitElements($pipelineAst.PipelineElements)
        return [PipelineAst]::new($pipelineAst.Extent, $newPipeElements)
    }

    [object] VisitCommand([CommandAst] $commandAst)
    {
        $newCommandElements = $this.VisitElements($commandAst.CommandElements)
        $newRedirections = $this.VisitElements($commandAst.Redirections)
        return [CommandAst]::new($commandAst.Extent, $newCommandElements, $commandAst.InvocationOperator, $newRedirections)
    }

    [object] VisitCommandExpression([CommandExpressionAst] $commandExpressionAst)
    {
        $newExpression = $this.VisitElement($commandExpressionAst.Expression)
        $newRedirections = $this.VisitElements($commandExpressionAst.Redirections)
        return [CommandExpressionAst]::new($commandExpressionAst.Extent, $newExpression, $newRedirections)
    }

    [object] VisitCommandParameter([CommandParameterAst] $commandParameterAst)
    {
        $newArgument = $this.VisitElement($commandParameterAst.Argument)
        return [CommandParameterAst]::new($commandParameterAst.Extent, $commandParameterAst.ParameterName, $newArgument, $commandParameterAst.ErrorPosition)
    }

    [object] VisitFileRedirection([FileRedirectionAst] $fileRedirectionAst)
    {
        $newFile = $this.VisitElement($fileRedirectionAst.Location)
        return [FileRedirectionAst]::new($fileRedirectionAst.Extent, $fileRedirectionAst.FromStream, $newFile, $fileRedirectionAst.Append)
    }

    [object] VisitMergingRedirection([MergingRedirectionAst] $mergingRedirectionAst)
    {
        return [MergingRedirectionAst]::new($mergingRedirectionAst.Extent, $mergingRedirectionAst.FromStream, $mergingRedirectionAst.ToStream)
    }

    [object] VisitBinaryExpression([BinaryExpressionAst] $binaryExpressionAst)
    {
        $newLeft = $this.VisitElement($binaryExpressionAst.Left)
        $newRight = $this.VisitElement($binaryExpressionAst.Right)
        return [BinaryExpressionAst]::new($binaryExpressionAst.Extent, $newLeft, $binaryExpressionAst.Operator, $newRight, $binaryExpressionAst.ErrorPosition)
    }

    [object] VisitUnaryExpression([UnaryExpressionAst] $unaryExpressionAst)
    {
        $newChild = $this.VisitElement($unaryExpressionAst.Child)
        return [UnaryExpressionAst]::new($unaryExpressionAst.Extent, $unaryExpressionAst.TokenKind, $newChild)
    }

    [object] VisitConvertExpression([ConvertExpressionAst] $convertExpressionAst)
    {
        $newChild = $this.VisitElement($convertExpressionAst.Child)
        $newTypeConstraint = $this.VisitElement($convertExpressionAst.Type)
        return [ConvertExpressionAst]::new($convertExpressionAst.Extent, $newTypeConstraint, $newChild)
    }

    [object] VisitTypeExpression([TypeExpressionAst] $typeExpressionAst)
    {
        return [TypeExpressionAst]::new($typeExpressionAst.Extent, $typeExpressionAst.TypeName)
    }

    [object] VisitConstantExpression([ConstantExpressionAst] $constantExpressionAst)
    {
        return [ConstantExpressionAst]::new($constantExpressionAst.Extent, $constantExpressionAst.Value)
    }

    [object] VisitStringConstantExpression([StringConstantExpressionAst] $stringConstantExpressionAst)
    {
        return [StringConstantExpressionAst]::new($stringConstantExpressionAst.Extent, $stringConstantExpressionAst.Value, $stringConstantExpressionAst.StringConstantType)
    }

    [object] VisitSubExpression([SubExpressionAst] $subExpressionAst)
    {
        $newStatementBlock = $this.VisitElement($subExpressionAst.SubExpression)
        return [SubExpressionAst]::new($subExpressionAst.Extent, $newStatementBlock)
    }

    [object] VisitUsingExpression([UsingExpressionAst] $usingExpressionAst)
    {
        $newUsingExpr = $this.VisitElement($usingExpressionAst.SubExpression)
        return [UsingExpressionAst]::new($usingExpressionAst.Extent, $newUsingExpr)
    }

    [object] VisitVariableExpression([VariableExpressionAst] $variableExpressionAst)
    {
        return [VariableExpressionAst]::new($variableExpressionAst.Extent, $variableExpressionAst.VariablePath.UserPath, $variableExpressionAst.Splatted)
    }

    [object] VisitMemberExpression([MemberExpressionAst] $memberExpressionAst)
    {
        $newExpr = $this.VisitElement($memberExpressionAst.Expression)
        $newMember = $this.VisitElement($memberExpressionAst.Member)
        return [MemberExpressionAst]::new($memberExpressionAst.Extent, $newExpr, $newMember, $memberExpressionAst.Static)
    }

    [object] VisitInvokeMemberExpression([InvokeMemberExpressionAst] $invokeMemberExpressionAst)
    {
        $newExpression = $this.VisitElement($invokeMemberExpressionAst.Expression)
        $newMethod = $this.VisitElement($invokeMemberExpressionAst.Member)
        $newArguments = $this.VisitElements($invokeMemberExpressionAst.Arguments)
        return [InvokeMemberExpressionAst]::new($invokeMemberExpressionAst.Extent, $newExpression, $newMethod, $newArguments, $invokeMemberExpressionAst.Static)
    }

    [object] VisitArrayExpression([ArrayExpressionAst] $arrayExpressionAst)
    {
        $newStatementBlock = $this.VisitElement($arrayExpressionAst.SubExpression)
        return [ArrayExpressionAst]::new($arrayExpressionAst.Extent, $newStatementBlock)
    }

    [object] VisitArrayLiteral([ArrayLiteralAst] $arrayLiteralAst)
    {
        $newArrayElements = $this.VisitElements($arrayLiteralAst.Elements)
        return [ArrayLiteralAst]::new($arrayLiteralAst.Extent, $newArrayElements)
    }

    [object] VisitHashtable([HashtableAst] $hashtableAst)
    {
        $newKeyValuePairs = [List[Tuple[ExpressionAst,StatementAst]]]::new()
        foreach ($keyValuePair in $hashtableAst.KeyValuePairs)
        {
            $newKey = $this.VisitElement($keyValuePair.Item1);
            $newValue = $this.VisitElement($keyValuePair.Item2);
            $newKeyValuePairs.Add([Tuple[ExpressionAst,StatementAst]]::new($newKey, $newValue)) # TODO NOT SURE
        }
        return [HashtableAst]::new($hashtableAst.Extent, $newKeyValuePairs)
    }

    [object] VisitScriptBlockExpression([ScriptBlockExpressionAst] $scriptBlockExpressionAst)
    {
        $newScriptBlock = $this.VisitElement($scriptBlockExpressionAst.ScriptBlock)
        return [ScriptBlockExpressionAst]::new($scriptBlockExpressionAst.Extent, $newScriptBlock)
    }

    [object] VisitParenExpression([ParenExpressionAst] $parenExpressionAst)
    {
        $newPipeline = $this.VisitElement($parenExpressionAst.Pipeline)
        return [ParenExpressionAst]::new($parenExpressionAst.Extent, $newPipeline)
    }

    [object] VisitExpandableStringExpression([ExpandableStringExpressionAst] $expandableStringExpressionAst)
    {
        try {
            
            return [ExpandableStringExpressionAst]::new($expandableStringExpressionAst.Extent,$expandableStringExpressionAst.Value,$expandableStringExpressionAst.StringConstantType)
        }
        catch {
            # "$exceptionName`: $($thisLines[0])" <- fails on the backtick
            #      | Exception calling ".ctor" with "3" argument(s): "At line:1 char:2 + "$exceptionName: $($thisLines[0])" +  ~~~~~~~~~~~~~~~ Variable reference is not valid. ':' was not followed by a valid variable name character. Consider using ${} to
            # | delimit the name."
            return $expandableStringExpressionAst.Copy()
        }
    }

    [object] VisitIndexExpression([IndexExpressionAst] $indexExpressionAst)
    {
        $newTargetExpression = $this.VisitElement($indexExpressionAst.Target)
        $newIndexExpression = $this.VisitElement($indexExpressionAst.Index)
        return [IndexExpressionAst]::new($indexExpressionAst.Extent, $newTargetExpression, $newIndexExpression)
    }

    [object] VisitAttributedExpression([AttributedExpressionAst] $attributedExpressionAst)
    {
        $newAttribute = $this.VisitElement($attributedExpressionAst.Attribute)
        $newChild = $this.VisitElement($attributedExpressionAst.Child)
        return [AttributedExpressionAst]::new($attributedExpressionAst.Extent, $newAttribute, $newChild)
    }

    [object] VisitBlockStatement([BlockStatementAst] $blockStatementAst)
    {
        $newBody = $this.VisitElement($blockStatementAst.Body)
        return [BlockStatementAst]::new($blockStatementAst.Extent, $blockStatementAst.Kind, $newBody)
    }
}
#endregion
