@{
    # PSScriptAnalyzer configuration for Merge-MkvAudio.
    #
    # Error and Warning severities run. Errors gate commits and CI; Warnings
    # are advisory. Excluded rules conflict with deliberate design choices:
    #
    #   PSAvoidUsingWriteHost
    #     Merge-MkvAudio is an interactive console tool; its output is meant
    #     for the person running it, with colour, not for the pipeline.
    #
    #   PSUseShouldProcessForStateChangingFunctions
    #     Fires on pure builders (New-MergePlan, New-MkvMergeArgument and test
    #     helpers) that return an object without changing anything. The script
    #     itself, which does write files, supports -WhatIf.
    #
    # Anything else that is intentional is suppressed at the call site with a
    # justification, not excluded here.

    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
