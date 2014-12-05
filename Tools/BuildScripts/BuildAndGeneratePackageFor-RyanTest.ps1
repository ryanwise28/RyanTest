& .\build.ps1 -taskList Build -properties @{ `
		cpucount = 1; `
        buildnumber = $env:BUILD_NUMBER; `
		solutionsToTarget = "RyanTest.sln"; `
		nugetPackagesToCreate = "RyanTest.nuspec"; `
};
if (!$?) {exit 1}