# ─────────────────────────────────────────────────────────────────────────────
# PSScriptAnalyzerSettings.psd1
#
# Project-wide PSScriptAnalyzer settings for Azure Demo Environment.
#
# Usage (local):
#   Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
#
# The CI lint workflow automatically picks this file up via -Settings.
# ─────────────────────────────────────────────────────────────────────────────
@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(

        # ADE scripts are interactive CLI tools that deliberately use Write-Host
        # for coloured output (level-tagged log lines, section banners, summaries).
        # These are not library modules where Write-Output would be appropriate.
        'PSAvoidUsingWriteHost',

        # UTF-8 without BOM is the project encoding standard (consistent with
        # Linux tooling, VS Code defaults, and GitHub Actions runners).
        'PSUseBOMForUnicodeEncodedFile',

        # Internal helper functions use domain verbs (Deploy-AdeModule,
        # Build-AdeTags, Confirm-AdeDeployment) that are not in the approved PS
        # verb list but are clear and idiomatic within this domain.
        'PSUseApprovedVerbs',

        # Established plural function names (Test-AdePrerequisites, Build-AdeTags)
        # are public API surface referenced throughout the codebase and in docs.
        'PSUseSingularNouns',

        # The -Profile parameter is used by convention across all deploy/validate
        # functions. Inside function scope it is a local binding and does not
        # affect $PROFILE (the host profile script path automatic variable).
        'PSAvoidAssignmentToAutomaticVariable',

        # PSScriptAnalyzer cannot resolve variable usage across switch-case blocks
        # or PowerShell -f format strings, producing false positives for $bicep,
        # $params, $barFilled, $barEmpty, etc. Genuine dead-code cases are fixed
        # directly in the source (see commit history).
        'PSUseDeclaredVarsMoreThanAssignments',

        # PSScriptAnalyzer does not track -WhatIf:$WhatIf pass-through patterns
        # or $PSBoundParameters.ContainsKey() usage, flagging live parameters as
        # unused. Genuine unused parameters are fixed directly in the source.
        'PSReviewUnusedParameter',

        # ConvertTo-SecureString -AsPlainText is used in demo/test contexts where
        # the value originates from a secret store (Key Vault, GitHub Actions secret)
        # and not from untrusted user input. Acceptable for a demo environment.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
