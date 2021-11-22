module Sentinel
    using CUDA
    using ArchGDAL
    using Base
    using NamedArrays
    using Metadata
    using Interpolations
    using Graphics
    using Images
    using GoogleCloud
    using CSV
    using CSVFiles
    using DataFrames
    using JSON
    using Printf
    using LightXML
    using Base64
    using Glob
    using Dates

    export resizeCuda, linearKernel, loadSentinel, scanInvert, cudaScan, cudaRevScan, cudaCirrusScan, sentinelCloudScreen, generateScreens, applyScreens, saveScreenedRasters, cloudInit, safeList, filterList, loadSentinel
   
    function resizeCuda(inputArray, inputWidth, inputHeight; returnGPU = false, interpolation=true)
        textureArray = CuTextureArray(inputArray)
        if interpolation == true
            texture = CuTexture(textureArray; normalized_coordinates=true, interpolation=CUDA.LinearInterpolation())
        else 
            texture = CuTexture(textureArray; normalized_coordinates=true)
        end
        outputCUDAArray = CuArray{eltype(inputArray)}(undef, inputWidth, inputHeight)
        k = @cuda launch=false linearKernel(outputCUDAArray, texture)
        config = launch_configuration(k.fun)
        threads = Base.min(length(outputCUDAArray), config.threads)
        blocks = cld(length(outputCUDAArray), threads)
        @cuda threads=threads blocks=blocks linearKernel(outputCUDAArray, texture)
        if returnGPU == false
            outputArray = Array{eltype(inputArray)}(outputCUDAArray)
            return outputArray
        else 
            return outputCUDAArray
        end
    end

    # Linear Kernel
    function linearKernel(output, input)
        tid = threadIdx().x + (blockIdx().x - 1) * blockDim().x
        I = CartesianIndices(output)
        @inbounds if tid <= length(I)
            i,j = Tuple(I[tid])
            u = Float16(i-1) / Float16(size(output, 1)-1)
            v = Float16(j-1) / Float16(size(output, 2)-1)
            x = u
            y = v
            output[i,j] = input[x,y]
        end
        return
    end

    function pn(x) 
        @printf "%f" maximum(x)
    end

    function loadSentinel(tif; GPU=false)
        tifArray = Dict()
        origString = tif * "/MTD_MSIL2A.xml"
        safeMeta = ArchGDAL.read(origString)
        safeBasicMetaData = ArchGDAL.metadata(safeMeta)
        fileNames = ArchGDAL.metadata(safeMeta; domain="SUBDATASETS")
        fileList = split.(fileNames[occursin.("NAME", fileNames)], "=")
        cnt = 1
        for i in fileList
            fileBand = i[2]
            resolution = split(fileBand, ":")[3]
            if resolution != "TCI"
                ArchGDAL.read(fileBand) do dataset
                    number_rasters = (ArchGDAL.nraster(dataset))
                    ref = ArchGDAL.getproj(dataset)
                    geotransform = ArchGDAL.getgeotransform(dataset)
                    for bandCounter in 1:number_rasters
                        bandInfo = ArchGDAL.getband(dataset, bandCounter)
                        metaDataItem = ArchGDAL.metadataitem(bandInfo, "BANDNAME", domain="")
                        GPU == true ? band = CuArray{Float16}(ArchGDAL.read(bandInfo)) : band = Array{Int32}(ArchGDAL.read(bandInfo))
                        bandMetaData = Dict("band_data" => ArchGDAL.metadata(bandInfo), 
                                            "location" =>  ArchGDAL.metadata(bandInfo; domain="LocationInfo"), 
                                            "image_structure" => ArchGDAL.metadata(bandInfo; domain="IMAGE_STRUCTURE"#, 
                                            ))  
                        sentRaster = Dict("$metaDataItem-$resolution" => band)
                        tifArray = merge!(tifArray, sentRaster)
                        tifArray["$metaDataItem-$resolution"] = attach_metadata(tifArray["$metaDataItem-$resolution"], Dict("metadata" => bandMetaData, "filedata" => safeBasicMetaData, "ref" => ref, "geotransform" => geotransform))
                        cnt = cnt + 1
                        band = nothing
                    end
                end
            end
        end
        return tifArray
    end

    # Scan Code for CUDA Screens
    scanInvert(x, z) = (x > convert(typeof(x), z) ? x = convert(typeof(x), 1) : x = convert(typeof(x), 0))

    function cudaScan(x, y, z)
        z = convert(eltype(x), z)
        yNull = convert(typeof(y), 0)

        if x > z
            if y != yNull
                y = yNull
            end
        end
        return y
    end

    function cudaRevScan(x, y, z)
        z = convert(typeof(x){elmtype}, z)
        yNull = convert(typeof(y), 0)
        if x < z
            if y != yNull
                y = yNull
            end
        end
        return y
    end

    cudaInvert(x) = (x == 1.0 ? x = 0.0 : x = 1.0)

    cudaBitScan(x,y) = (x == convert(typeof(x), 0) || y == convert(typeof(x), 0) ? convert(typeof(x), 0) : convert(typeof(x), 1))

    scanMean(x, y) = ((x+y)/ convert(typeof(y), 2))

    scanFind(x, y) = (x == convert(typeof(x), y) ? x : convert(typeof(x), 0))

    scanGreaterThan(x, y) = (x > convert(typeof(x), y) ? x : convert(typeof(x), 0))

    #Array(broadcast(scanMean, parent(gpuOne["B1-Screened"]), parent(gpuOne["B2-Screened"]))) Pansharpening Code

    function cudaCirrusScan(x, y, lower, upper)
        lower = convert(eltype(x), lower)
        upper = convert(eltype(x), upper)
        yNull = convert(eltype(y), 0)
        if y == yNull
            y = yNull
        elseif x > upper
            y = yNull
        elseif x < lower
            y = yNull
        end
        return y
    end

    # Create Screen (CUDA Only)

    function sentinelCloudScreen(targetFile, screenFile; b1Screen = 1000, b2Screen = 1000, b4Screen = 1000, cloudMaskScreen = 20, GPU=true, GPU_All = false)
        #println("Starting Cloud Screen")
        # Users can pass either a string to the SAFE file location or preloaded Abstract Arrays
        if typeof(targetFile) == String
            #println("Loading Files")
            imageBandsA = loadSentinel(targetFile) 
            imageBandsB = loadSentinel(screenFile) 
        else
            #println("Selecting Bands")
            imageBandsA = targetFile
            imageBandsB = screenFile
        end

        function processScreens(imageBands1, imageBands2; GPU=true, GPU_All = false)
            #println("Processing Cloud Screens")
            # Loads B1, B2, B4, B9, Cloud Screen, and Surface Classification (Cirrus Cloud Detection)
            b1 = parent(imageBands1["B1-60m"])
            b2 = parent(imageBands2["B1-60m"])
            #n1 = parent(imageBands1["B9-60m"])
            #n2 = parent(imageBands2["B9-60m"])
            c2 = parent(imageBands2["CLD-60m"])
            s2 = parent(imageBands2["SCL-60m"])
            bl1 = parent(imageBands1["B2-10m"])
            bl2 = parent(imageBands2["B2-10m"])
            r1 = parent(imageBands1["B4-10m"])
            r2 = parent(imageBands2["B4-10m"])

            if GPU_All == false
                #println("CPU")
                # Apply B1 Time Screen
                t1 = b2 - b1
                t1a = BitArray(zeros(width(t1), height(t1)))
                tvec = findall(t1 .> b1Screen)
                t1a[tvec] .= 1

                # Apply B9 Time Screen
                #nScreen = n2 - n1
                #nVec = findall(nScreen .> b9Screen)
                #t1a[nVec] .= 1

                # Apply Sen2Cor Cloud Mask Screen
                cvec = findall(c2 .> cloudMaskScreen)
                t1a[cvec] .= 1

                # Apply Cirrus Cloud Screen
                t1a = .!t1a
                t1a = broadcast(cudaCirrusScan, s2, t1a, 1, 8)
                
                # Process Cloud Screen - Cloud Masks are always at 10m
                GPU == true ? cloudScreen = resizeCuda(CuArray(Array{Float16}(t1a)), width(r1), height(r1); interpolation=false) : cloudScreen = Images.imresize(t1a, width(r1), height(r1));
                testVec = findall(cloudScreen .< 1)
                cloudScreen[testVec] .= 0
                cloudScreen = BitArray(cloudScreen)

                # Apply B2 Time Screen
                bScreen = bl2 - bl1
                blVec = findall(bScreen .> b2Screen)
                cloudScreen[blVec] .= 0

                # Apply B4 Time Screen
                rScreen = r2 - r1
                rVec = findall(rScreen .> b4Screen)
                cloudScreen[rVec] .= 0
                return cloudScreen
            else 
                #println("GPU")

                # Apply B1 Time Screen
                t1 = b2 - b1
                t1a = broadcast(cudaScan, t1, 1.0, b1Screen)

                # Apply B9 Time Screen
                #nScreen = n2 - n1
                #t1a = broadcast(cudaScan, nScreen, t1a, b9Screen)

                # Apply Sen2Cor Cloud Mask Screen
                t1a = broadcast(cudaScan, c2, t1a, cloudMaskScreen)

                # Apply Cirrus Cloud Screen
                t1a = broadcast(cudaCirrusScan, s2, t1a, 1, 8)

                # Process Cloud Screen - Cloud Masks are always at 10m
                cloudScreen = resizeCuda(CuArray{Float16}(t1a), width(r1), height(r1); returnGPU = true);
                cloudScreen = broadcast(cudaCirrusScan, cloudScreen, cloudScreen, 1, 1)

                # Apply B2 Time Screen
                bScreen = bl2 - bl1
                cloudScreen = broadcast(cudaScan, bScreen, cloudScreen, b2Screen)

                # Apply B4 Time Screen
                rScreen = r2 - r1
                cloudScreen = broadcast(cudaScan, rScreen, cloudScreen, b4Screen)
                t1 = nothing
                t1a = nothing
                bScreen = nothing
                rScreen = nothing   
                return cloudScreen
            end
        end
        screenOne = processScreens(imageBandsA, imageBandsB; GPU=GPU, GPU_All=GPU_All)
        screenTwo = processScreens(imageBandsB, imageBandsA; GPU=GPU, GPU_All=GPU_All)
        return screenOne, screenTwo 
    end

    function generateScreens(files; b1Screen = 1000, b2Screen = 1000, b4Screen = 1000, cloudMaskScreen = 20, GPU=true)
        for i in 1:length(files)
            fileA = files[i]
            if i != length(files)
                for j in i+1:length(files) 
                    fileB = files[j]
                    targetScreen, screenScreen = sentinelCloudScreen(fileA, fileB; b1Screen = b1Screen, b2Screen = b2Screen, b4Screen = b4Screen, cloudMaskScreen = cloudMaskScreen, GPU=GPU, GPU_All = GPU)
                    haskey(fileA, "CloudScreen") == true ? fileA["CloudScreen"] = broadcast(cudaBitScan, fileA["CloudScreen"], screenScreen) : fileA["CloudScreen"] = screenScreen
                    haskey(fileB, "CloudScreen") == true ? fileB["CloudScreen"] = broadcast(cudaBitScan, fileB["CloudScreen"], targetScreen) : fileB["CloudScreen"] = targetScreen
                    targetScreen = nothing
                    screenScreen = nothing
                end
            end
        end
        return
    end

    function applyScreens(files; GPU = true) 
        for file in files
            if haskey(file, "CloudScreen")
                for i in keys(file)
                    if i[1] == 'B'
                        keyName = split(i, "-")
                        tmpScreen = parent(file[i])
                        if size(file[i]) != size(file["CloudScreen"])
                            tmpScreen = resizeCuda(tmpScreen, width(file["CloudScreen"]), height(file["CloudScreen"]); returnGPU = GPU);
                        end
                        bandName = keyName[1] * "-Screened"
                        file[bandName] = tmpScreen .* file["CloudScreen"]
                    end
                end
            end
        end
        return
    end

    function scanMerge(x...; screen = 0) 
        count = 0
        y = convert(eltype(x[1]), 0)
        screen = convert(eltype(x[1]), screen)
        for i in x
            if i > screen
                y = y + i
                count = count + 1
            end
        end
        if count != 0
            y = y / convert(typeof(y), count)
        end
        return y
    end

    function scanMaxMerge(x...) 
        #y = convert(eltype(x[1]), x[1])
        y = x[1]
        for i in x
            if i > y
                y = i
            end
        end
        return y
    end

    function saveScreenedRasters(x...; names=[], type=UInt16)
        for i in 1:length(x)
            file = x[i]
            name = names[i]
            bandCount = 0
            bandList = []

            for j in keys(file)
                if j != "CloudScreen"
                    keyName = split(j, "-")
                    #@show j, keyName = split(j, "-")
                    if keyName[2] == "Screened"
                        append!(bandList, [j])
                        bandCount = bandCount + 1
                    end
                end
            end
            geoTransform = file["CLD-20m"].geotransform
            ref = file["CLD-20m"].ref
            bandWidth = width(parent(file["B2-10m"]))
            bandHeight = height(parent(file["B2-10m"]))
            ArchGDAL.create(name; driver=ArchGDAL.getdriver("GTiff"), width=bandWidth, height=bandHeight, nbands=bandCount, dtype=type) do raster
                ArchGDAL.setgeotransform!(raster, geoTransform)
                ArchGDAL.setproj!(raster, ref)
                for k in 1:bandCount
                    rast = broadcast(trunc, parent(file[bandList[k]]))
                    rast = Array{type}(rast)
                    ArchGDAL.write!(raster, rast, k)
                    ArchGDAL.getband(raster, k) do band
                        ArchGDAL.setcategorynames!(band, [bandList[k]])                    
                    end
                end
            
            end
        end
    end

    function generateCloudless(files...)
        file = copy(files[1])
        keyList = keys(file)
        for key in keyList
            if key != "CloudScreen"
                if last(key, 8) == "Screened"
                    file[key] = broadcast(Sentinel.scanMaxMerge, map((x) -> parent(x[key]), files)...);
                end
            end
        end
        return file
    end

    export generateCloudless, resizeCuda, linearkernel, loadSentinel, scanInvert, cudaScan, cudaRevScan, cudaInvert, cudaBitScan, scanMean, scanFind, scanGreaterThan, cudaCirrusScan, sentinelCloudScreen, generateScreens, applyScreens, scanMerge, scanMaxMerge, saveScreenedRasters

    function cloudDownload(location; writeFile = true)
        collData = GoogleCloud.storage(:Object, :get, "gcp-public-data-sentinel-2", location) 
        if writeFile == true
            open(location, "w") do file
                write(file, collData)
            end
        else
            io = IOBuffer();
            write(io, collData);
            return io
        end 
    end

    function obtain(SAFE)
        mkpath(SAFE)
        rawFileList = GoogleCloud.storage(:Object, :list, "gcp-public-data-sentinel-2"; prefix=SAFE, deliminater="/")
        io = IOBuffer();
        write(io, rawFileList);
        fileList = String(take!(io));
        fileList = JSON.parse(fileList);
        for item in fileList["items"]
            if occursin("_\$folder\$", item["name"]) == true
                folderPath = chop(item["name"], head=0, tail=9)
                mkpath(folderPath)
            else
                filePath = SubString.(item["name"], 1, findlast(==('/'),item["name"]))
                mkpath(filePath)
                cloudDownload(item["name"]) 
            end
        end
    end

    function safeList(; cache="~/.img_cache", update=true)
        currentDirectory = pwd()
        mkpath(cache)
        cd(cache)
        if isfile("cacheIndex.csv.gz") == true & update == false
            df = DataFrame(load(File(format"CSV", "cacheIndex.csv.gz")))
        else 
            obs = GoogleCloud.storage(:Object, :get, "gcp-public-data-sentinel-2", "L2/index.csv.gz")
            open("cacheIndex.csv.gz", "w") do file
                write(file, obs)
            end
            df = DataFrame(load(File(format"CSV", "cacheIndex.csv.gz")))
        end
        cd(currentDirectory)
        return df
    end

    function sentinelFiveList(startDay, endDay; platform = "Sentinel-5", user = "s5pguest", pass = "s5pguest", start = 0, rows = 100)
        # Format Dates
        sDate = string(DateTime(startDay, "yyyymmdd"), "Z")
        eDate = string(DateTime(endDay, "yyyymmdd"), "Z")
        # Get XML
        xmlRoot, next = processSentHTML(user, pass, platform, start, rows, sDate, eDate)
        println(next)
        files = cleanSentXML(xmlRoot)
        while next != 0
          start = start + rows
          xmlRoot, next = processSentHTML(user, pass, platform, start, rows, sDate, eDate)
          println(next)
          itrFiles = cleanSentXML(xmlRoot)
          files = [files; itrFiles]
        end
        return files
    end

    function cleanSentXML(xmlRoot)
        files = DataFrame(title = String[], href = String[], fileName = String[], abbr = String[], desc = String[], uuid = String[])
        entries = xmlRoot["entry"]
        title = ""
        href = ""
        fileName = ""
        abbr = ""
        desc = ""
        uuid = ""
        for i in entries
            title = content(i["title"][1])
            linkList = i["link"]
            strList = i["str"]
            href = LightXML.attribute(linkList[1], "href")
        
            for j in strList 
            println(j)
            if LightXML.attribute(j, "name") == "filename"
                fileName = content(j)
            elseif LightXML.attribute(j, "name") == "processingmodeabbreviation"
                abbr = content(j)
            elseif LightXML.attribute(j, "name") == "producttypedescription"
                desc = content(j)
            elseif LightXML.attribute(j, "name") == "uuid"
                uuid = content(j)
            end
            end
            push!(files, (title, href, fileName, abbr, desc, uuid))
        end
        return files
    end
    
    function processSentHTML(user, pass, platform, start, rows, sDate, eDate)
        # Create HTTP Get Request
        link = "https://$user:$pass@s5phub.copernicus.eu/search?start=$start&rows=$rows&q="
        queryString = string("(platformname:$platform%20AND%20beginposition:%5b$sDate%20TO%20$eDate%5d)")
        url = string(link, queryString)
        
        # Get File List
        println("Getting: $url")
        resp = HTTP.get(url)
        println(resp.request)
        x = String(resp.body)
        xmlExt = parse_string(x)
        xmlRoot = root(xmlExt)
        links = xmlRoot["link"]
        next = 0
        for i in links
            if LightXML.attribute(i, "rel") == "next"
            next = LightXML.attribute(i, "href")
            end
        end
        return xmlRoot, next
    end   
    
    function zulu()
        escaped_format = "yyyy-mm-dd\\THH:MM:SS.sss\\Z"
        Zulu = String
        Dates.CONVERSION_SPECIFIERS['Z'] = Zulu
        Dates.CONVERSION_DEFAULTS[Zulu] = ""
        df = Dates.DateFormat(escaped_format)
        return df
    end 
    
    function parseSentinelTime(time, format)
        parsedTime = DateTime(time, format)
        return parsedTime
    end
    
    function filterList(inputFile, mgrs, startDate, endDate; cover=10)
        format = zulu()
        subsetDF = subset(inputFile, 
                                    :MGRS_TILE => ByRow(x -> x == mgrs),
                                    :CLOUD_COVER => ByRow(x -> x < cover),
                                    :SENSING_TIME => ByRow(x -> parseSentinelTime(x, format) > startDate),
                                    :SENSING_TIME => ByRow(x -> parseSentinelTime(x, format) < endDate)
                                    )
        subsetDF = sort(subsetDF, (:CLOUD_COVER))
        return subsetDF
    end

    function downloadTiles(inputList, numberFiles; cache="~/.img_cache")
        currentDirectory = pwd()
        mkpath(cache)
        cd(cache)
        downloadStrings = replace.(inputList.BASE_URL[1:numberFiles], r"gs://gcp-public-data-sentinel-2/" => "")
        for safeUrl in downloadStrings
            Sentinel.obtain(safeUrl)
        end
        filePath = cache .* "/" .* SubString.(downloadStrings, 1, findlast.(==('/'), downloadStrings))
        cd(currentDirectory)
        return filePath[1]
    end

    function cloudInit(credentials) 
        creds = JSONCredentials(credentials)
        session = GoogleSession(creds, ["devstorage.full_control"])
        set_session!(storage, session) 
    end

    function downloadSentinelFive(urlList; cache=pwd())
        for i in urlList
          print(i)
          authEncode = "Basic " * base64encode("s5pguest" * ":" * "s5pguest")
          auth = Dict("Authorization" => authEncode)
          HTTP.download(i, cache; headers = auth)
        end 
    end

    function bashDownloadSentinelFive(urlList; cache=pwd())
        currDir = pwd()
        cd(cache)
        outFile = open("links", "w")
        for i in urlList
            println(outFile, i)
        end
        close(outFile)
        parDownload = pipeline(`cat links`, `xargs -d "\n" -P 15 -L 1 wget --content-disposition --continue --user=s5pguest --password=s5pguest`)
        run(parDownload)
        cd(currDir)
    end
end

