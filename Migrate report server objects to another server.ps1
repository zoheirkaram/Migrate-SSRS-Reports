cls

$sourceService = "http://SourceServer/ReportServer/reportservice2010.asmx"
$proxySource = New-WebServiceProxy -Class 'RS1' -Uri $sourceService -UseDefaultCredential

$sourceService = "http://TargetService/ReportServer/reportservice2010.asmx"
$proxyTarget = New-WebServiceProxy -Class 'RS2' -Uri $sourceService -UseDefaultCredential

$warnings = $null

#create folder structure by copying from source to target
CopyFolderStructure -path "/" -dService $proxyTarget -sService $proxySource

$datasets = $proxySource.ListChildren("/", $true) | where {$_.TypeName -eq "DataSet"}
$datasources = $proxySource.ListChildren("/", $true) | where {$_.TypeName -eq "DataSource"}
$folders = $proxySource.ListChildren("/", $true) | where {$_.TypeName -eq "Folder"}

#include root folder in the structure
$parent = New-Object("$($proxyTarget.GetType().Namespace).CatalogItem")
$parent.Name = "Root"
$parent.Path = "/"
$parent.TypeName = "Folder"
$folders += $parent

Write-Host("Finish creating folder structure") -ForegroundColor Cyan

#copy data sources
foreach($datasource in $datasources){
    $dsDef = $proxySource.GetItemDefinition($datasource.Path)

    $dsrParent = $proxySource.ListParents($datasource.path)[0]
    if ($dsrParent.Path -ne "/"){
        $dsrParent = CreateFolderIfNotExists -folderPath $dsrParent.Path -folderName $dsrParent.Name -dService $proxyTarget -sService $proxySource
    }

    try {
        $proxyTarget.CreateCatalogItem("DataSource", $datasource.Name, $dsrParent.Path, $true, $dsDef, $null, [ref] $warnings)
    } catch {
        Write-Host("Error creating $($datasource.Name) in desination") -ForegroundColor Red
    }
}

Write-Host("Finish creating data sources") -ForegroundColor Cyan

#copy data sets
foreach($dataset in $datasets){
    $dstDef = $proxySource.GetItemDefinition($dataset.Path)

    $dstParent = $proxySource.ListParents($dataset.path)[0]
    if ($dstParent.Path -ne "/"){
        $dstParent = CreateFolderIfNotExists -folderPath $dstParent.Path -folderName $dstParent.Name -dService $proxyTarget -sService $proxySource
    }

    $sourceDstRef = $proxySource.GetItemReferences($dataset.Path, "DataSet")
    $newDstRef = New-Object("$($proxyTarget.GetType().Namespace).ItemReference")
    $newDstRef.Name = $sourceDstRef[0].Name
    $newDstRef.Reference = $sourceDstRef[0].Reference

    try {
        $newDst = $proxyTarget.CreateCatalogItem("DataSet", $dataset.Name, $dstParent.Path, $true, $dstDef, $null, [ref] $warnings)
    } catch {
        Write-Host("Error creating DataSet: $($dataset.Name) in desination") -ForegroundColor Red
    }

    try {
        $proxyTarget.SetItemReferences($newDst.Path, $newDstRef)
    } catch {
        Write-Host("Error Referencing DataSource: $($newDstRef.Name) in DataSet: $($newDst.Name)") -ForegroundColor Red
    }

}

Write-Host("Finish creating data sets") -ForegroundColor Cyan

#copy reports
foreach($folder in $folders){
    
    $reports = $proxySource.ListChildren($folder.Path, $false) | where {$_.TypeName -eq "Report"}
    foreach($report in $reports)
    {
        $isReportCopied = $true
        try
        {
            $reportDefinition = $proxySource.GetItemDefinition($report.Path)            
            $newReport = $proxyTarget.CreateCatalogItem($report.TypeName, $report.Name, $folder.Path, $true, $reportDefinition, $null, [ref] $warnings)

        } catch {
            $isReportCopied = $false
            Write-Host("Report $($report.Name) faild to copy from source to destination") -ForegroundColor Red
        }

        if ($isReportCopied){
            try # assign datasource
            {
                $sourceDataSources = $proxySource.GetItemDataSources($report.Path)
                $targetDataSources = $proxyTarget.GetItemDataSources($report.Path)

                $dsRef = New-Object("$($proxyTarget.GetType().Namespace).DataSourceReference")
                $dsRef.Reference = $sourceDataSources[0].Item.Reference
                $targetDataSources[0].Item = $dsRef

                $proxyTarget.SetItemDataSources($newReport.Path, $targetDataSources)
            } catch {
                Write-Host("Cannot assign $($sourceDataSources[0].Name) DataSource to the report $($report.Name)") -ForegroundColor Red
            }

            try #assign dataset references
            {
                $reportDataSetRefs = $proxySource.GetItemReferences($report.Path, "DataSet")
                if ($reportDataSetRefs.Count -gt 0){
                    for($ref = 0; $ref -lt $reportDataSetRefs.Count; $ref++){
                        $newReportDataSetRef = New-Object("$($proxyTarget.GetType().Namespace).ItemReference")
                        $newReportDataSetRef.Name = $reportDataSetRefs[$ref].Name
                        $newReportDataSetRef.Reference = $reportDataSetRefs[$ref].Reference
                        $proxyTarget.SetItemReferences($newReport.Path, $newReportDataSetRef)
                    }
                }
            } catch {
                Write-Host("Cannot assign $($newReportDataSetRef.Name) DataSet to the report $($report.Name)") -ForegroundColor Red
            }

        }
        Write-Host("Finish creating report $($report.Name) in folder $($folder.Name)") -ForegroundColor Yellow
    }

    Write-Host("Finish creating reports in $($folder.Name)") -ForegroundColor Cyan
}

############ Functions ##############

function CreateFolderIfNotExists {
    param(
        [String] $folderPath, 
        [String] $folderName, 
        [System.Web.Services.Protocols.SoapHttpClientProtocol] $dService, #destination service
        [System.Web.Services.Protocols.SoapHttpClientProtocol] $sService  #source service
    )
    try{
        $parentPath = $sService.ListParents($folderPath)[0].Path
        $items = $dService.ListChildren($parentPath, $false) | where {$_.TypeName -eq 'Folder' -and $_.Name -eq $folderName}
        if ($items.count -eq 0){
            $dService.CreateFolder($folderName, $parentPath, $null)
        } else {
            $items[0]
        }
    } catch {
        Write-Host ("Cannot create $($folderName) in path $($folderPath)") -ForegroundColor Red
    }
}

function GetObjectNameFromPath {
    param(
        [String] $path
    )
    $indexOfSep = $path.LastIndexOf("/")
    $path.Substring($indexOfSep + 1, $path.Length - $indexOfSep - 1)
}

function CopyFolderStructure{
    param(
        [String] $path,
        [System.Web.Services.Protocols.SoapHttpClientProtocol] $dService, #destination service
        [System.Web.Services.Protocols.SoapHttpClientProtocol] $sService  #source service
    )
    try{
        $children = $proxySource.ListChildren($path, $false) | where {$_.TypeName -eq 'Folder'}
        if ($children.Count -gt 0){
            foreach($child in $children){            
                CopyFolderStructure -path $child.Path -dService $dService -sService $sService
                CreateFolderIfNotExists -folderPath $child.Path -folderName $child.Name -dService $dService -sService $sService
            }
        }
    } catch {
        Write-Host("Error while copying folder structure Path: $($path)")
    }
}