<#
  This is the main build file  
#>

Framework "4.0"

properties {
  $msbuild = "$env:windir\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe"
  
  #TargetProfile: Local - when running build locally; QA - when configuring to deploy on QA environment etc.
  $targetProfile = "Local"
  
  $basepath = resolve-path .
  $toolspath = "$basePath\tools"
  $outpath = "$basePath\bin\Release"
  $nuspecpath = "$basePath\nuspec"
  $srcpath = "$basePath\src"
  
  mkdir "$outpath" -erroraction silentlycontinue | out-null
  
  $nuget = "$outpath\nuget.exe"
  $cpuCount = 4
  $buildNumber = "0.0.13.0"
  
  # By default we want to target all solutions in the repository. Specific solutions can be targeted by setting this property.
  $solutionsToTarget = "*.sln"
  
  # By default we want to create NuGet packages for all NuSpec files in the repository. Specific NuGet packages can be created by setting this property.
  $nugetPackagesToCreate = "*.nuspec"
  
  # Use the default base folder for getting NuGet package files unless it is explicitly passed in
  $baseFolderForNuGetPackageFiles = "default"
}

TaskSetup {
    Report-Progress "$($psake.context.Peek().currentTaskName)"    
}

task default -depends Test
task Compile -depends CheckSources, CompileCore
task CopyDependentTools -depends CopySpecflowTools, CopyCustomReportXslts
task Build -depends RestorePackages, default, CreateNuGetPackages
task Test -depends Compile, RunUnitTests
task AcceptanceTests -depends RunAcceptanceTests, GenerateReport
task FixProj -depends FixStylecopSettings
task CheckSources -depends MustIncludeStylecop
task Rebuild -depends Clean, RestorePackages, default

task Clean {
    $solutionFiles = Get-ChildItem "$basepath" -recurse -filter $solutionsToTarget | select *
	
	foreach($solutionFile in $solutionFiles){
		$outputPath = "$outPath\" + $solutionFile.BaseName

		exec {& $msbuild $solutionFile.FullName /nologo /m:$cpuCount /nr:false /t:Clean /v:M /p:Configuration=Release /p:OutputPath="$outputPath" }
		del $outputPath -force -recurse -erroraction SilentlyContinue
	}	
}

task CompileCore {
    $solutionFiles = Get-ChildItem "$basepath" -recurse -filter $solutionsToTarget | select *
	
	foreach($solutionFile in $solutionFiles){
		$outputPath = "$outPath\" + $solutionFile.BaseName
		new-item "$outputPath" -type directory -erroraction SilentlyContinue > $null
		
		try
		{
			exec {& $msbuild $solutionFile.FullName /nologo /m:$cpuCount /nr:false /t:Build /v:M /fl /flp:LogFile="$outputPath\msbuild.log;Verbosity=Detailed" /p:Configuration=Release /p:OutputPath="$outputPath" /p:StyleCopEnabled=true /p:StyleCopTreatErrorsAsWarnings=false}
		}
		catch
		{
			exit -1
		}
	}
}

task RunUnitTests {
    try
    {
        $xunitrunner = ((ls .\packages\xUnit.Runners*) | select -First 1).FullName + "\tools\xunit.console.clr4.exe"
        ls -path $outpath -recurse -filter *.UnitTests.dll | foreach {
                "Running tests for {0}" -f $_.Name
				
				$reportFile = "$outpath\" + $_.BaseName + ".html"
                exec {& "$xunitrunner" $_.FullName /html "$reportFile" }
        }
    }
    catch
    {
        exit -1
    }
}

task RunAcceptanceTests -depends CopyDependentTools {
    try
    {
        $xunitrunner = ((ls .\packages\xUnit.Runners*) | select -First 1).FullName + "\tools\xunit.console.clr4.exe"
        ls -path $outpath -recurse -filter *.Acceptance.Tests.dll | foreach {
                "Running tests for {0}" -f $_.Name
				
				$nunitStyleReportXml = "$outpath\" + $_.BaseName + ".xml"
                exec {& "$xunitrunner" $_.FullName /nunit "$nunitStyleReportXml" }				
        }
    }
    catch
    {
    }
}

task GenerateReport -depends NunitStyleXmlPopulated {
	
	$testDll = ((ls -path $outpath -recurse -filter *.Acceptance.Tests.dll) | select -First 1)

	$projectFileName = $testDll.BaseName + ".csproj"
	$projectFile = ((ls -path $basepath -recurse -filter $projectFileName ) | select -First 1)
	"Generating test execution report for {0}" -f $projectFile.Name

	$nunitStyleReportXml = ((ls -path $outpath -recurse -filter *.Acceptance.Tests.xml) | select -First 1).FullName
	
	$specFlowExe = "$outpath\specFlowTools\specflow.exe"
	$testReportHtml = "$outpath\" + $testDll.BaseName + ".html"
	
	exec{& "$specFlowExe" nunitexecutionreport $projectFile.FullName /xmlTestResult:$nunitStyleReportXml /testOutput:"$outpath\TestOutput.txt" /out:$testReportHtml }	
}

task NunitStyleXmlPopulated {
	"Updating NUnit report XML to set Feature Title and Test Case Description"
	
	$nunitStyleReportXml = ((ls -path $outpath -recurse -filter *.Acceptance.Tests.xml) | select -First 1).FullName
	[xml] $reportXml = Get-Content $nunitStyleReportXml
	
	$features = $reportXml.SelectNodes('//test-suite[@type="TestFixture"]')
	
	foreach ($feature in $features){
		$featureName = $feature.SelectSingleNode('.//test-case/properties/property[@name="FeatureTitle"]').value
		
		$featureNameAttribute = $feature.Attributes.GetNamedItem('name')
		$nameAttributeValues = $featureNameAttribute.value.Split('.')
		
		$featureNameAttribute.value = $nameAttributeValues[$nameAttributeValues.Count - 1]
		
		$description = $reportXml.CreateAttribute('description')
		$description.Value = $featureName
		$feature.Attributes.InsertAfter($description, $feature.Attributes.GetNamedItem('name')) > $null
		
		$testcases = $feature.SelectNodes('.//test-case')
		
		foreach ($testcase in $testcases) {
			$testTitle = $testcase.SelectSingleNode('.//properties/property[@name="Description"]').value

			$testDescription = $reportXml.CreateAttribute('description')		
			$testDescription.Value = $testTitle
			
			$testcase.Attributes.InsertAfter($testDescription, $testcase.Attributes.GetNamedItem('name')) > $null
			
			$scenarioOutput = $testcase.SelectSingleNode('.//ScenarioOutput')
			
			$scenarioOutput.name >> "$outpath\TestOutput.txt"
			$scenarioOutput.InnerXml >> "$outpath\TestOutput.txt"
			$testcase.RemoveChild($scenarioOutput) > $null
			
			$testcase.RemoveChild($testcase.SelectSingleNode('.//properties')) > $null
		}
	}
	
	$reportXml.Save($nunitStyleReportXml)
}

task NuGet {
	new-item "$outPath" -type directory -erroraction SilentlyContinue > $null
    
    if(!(test-path "$nuget"))
    {
        (new-object net.webclient).DownloadFile("https://nuget.org/nuget.exe", "$nuget")
    }
}

task RestorePackages -depends NuGet {
    $solutionFiles = Get-ChildItem "$basepath\" -recurse -filter $solutionsToTarget | select *
    
	foreach($solutionFile in $solutionFiles) {
		Write-Host "Restoring packages for solution" $solutionFile.Name
		exec { & "$nuget" restore $solutionFile.FullName -config "$basePath\nuget.config" -source "https://nuget.org/api/v2/" -source "https://teamcity.moonpig.com/guestAuth/app/nuget/v1/FeedService.svc/"
		}	
	}
   
    exec { & "$nuget" install stylecop.msbuild -o "$basepath\packages" -excludeversion }
    exec { & "$nuget" install xunit.runners -o "$basepath\packages" -excludeversion }
}

task CreateNuGetPackages -depends NuGet {
	$nuspecFiles = Get-ChildItem "$basepath\NuSpec" -filter $nugetPackagesToCreate | select *
	
	foreach($nuspecFile in $nuspecFiles){
		$nuspecFileName = $nuspecFile.BaseName + ".$buildNumber.nupkg"

		Write-Host "Creating NuGet package $nuspecFileName"

		if($baseFolderForNuGetPackageFiles -eq "default") {
			$basePathForFiles = "$outpath\" + $nuspecFile.BaseName
		}
		else {
			$basePathForFiles = "$outpath\" + $baseFolderForNuGetPackageFiles
		}
		exec { & "$nuget" pack $nuspecFile.FullName -Version $buildNumber -BasePath $basePathForFiles  -OutputDirectory $outpath -NoPackageAnalysis }
	}
}

task Env {
  & "$toolspath\SetupIIS.ps1"
}

task CopySpecflowTools {
    "Copying Specflow Tools"
    $specflowpath = ((ls .\packages\Specflow*) | sort Name | select -First 1).FullName + "\tools\*"
	
	new-item "$outpath\specFlowTools" -type directory -erroraction SilentlyContinue > $null
    copy-item "$specflowpath" "$outpath\specFlowTools" -recurse -force > $null
	copy-item "$toolspath\ReportTemplates\specflow.exe.config" "$outpath\specFlowTools" -force > $null
}

task CopyCustomReportXslts {
	"Copying custom NUnitXml.Xslt to the xUnit runners"
	$xunitrunnerLocation = ((ls .\packages\xUnit.Runners*) | select -First 1).FullName + "\tools\"
	copy-item "$toolspath\ReportTemplates\NUnitXml.xslt" $xunitrunnerLocation -force > $null
}

task MustIncludeStylecop {
    $projects = Get-ProjectsMissingStylecop

    if($projects.Length -gt 0)
    {
        $projects | foreach { $_.Replace("$basepath\","") }
        throw "The above projects are missing stylecop settings. Run .\build FixProj to fix it."
    }
}

function Get-StylecopImportNode($projpath)
{
    $namespace = @{ msbuild="http://schemas.microsoft.com/developer/msbuild/2003" }
    $node = select-xml  -path $projpath -namespace $namespace `
                            -xpath "//msbuild:Import[@Project='`$([MSBuild]::GetDirectoryNameOfFileAbove(`$(MSBuildProjectDirectory),build.ps1))\tools\Settings.targets']"
    return $node
}

function Get-ProjectsMissingStylecop
{
    $projects = @()

    ls "$basepath" -filter *.csproj -recurse | foreach {
        $node = Get-StylecopImportNode $_.FullName
        if (!$node)
        {
            $projects += $_.FullName
        }
    }

    return $projects
}

task FixStylecopSettings {
    $projects = Get-ProjectsMissingStylecop

    if($projects.Length -gt 0)
    {
        $projects | foreach {
            Add-StylecopSettings $_
        }
    }
}

function Save-XmlFile($xml, $xmlpath)
{
    $doc = [xml] $xml.OuterXml.Replace(" xmlns=`"`"", "")
    [void] $doc.Save($xmlpath)
}

function Add-StylecopSettings($projpath)
{   
    $projxml = [xml](cat $projpath)
    $settingsNode = [xml]"<Import Project='`$([MSBuild]::GetDirectoryNameOfFileAbove(`$(MSBuildProjectDirectory),build.ps1))\tools\Settings.targets' />"
    $settingsNode = $projxml.ImportNode($settingsNode.Import, $true)
    [void] $projxml.Project.InsertBefore($settingsNode, $projxml.Project.FirstChild)
    Save-XmlFile $projxml $projpath
    "Added stylecop settings for {0}" -f $projpath.Replace("$basepath\", "")
}

function Get-File-Exists-On-Path
{
    param
    (
        [string]$file
    )
    $results = ($Env:Path).Split(";") | Get-ChildItem -filter $file -erroraction silentlycontinue
    $found = ($results -ne $null)
    return $found
}

function Report-Progress($message)
{   
    if($env:TEAMCITY_VERSION)
    {
        TeamCity-ReportBuildProgress $message
    }
    else {
        Write-Host $message
    }
}