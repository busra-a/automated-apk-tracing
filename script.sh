#Intercepts sigint and sigterm to kill the container on the way
trap exitScript INT TERM

#Prints with color
# args :
#  - option -n
#  - 1 color (r,b,g,y)
#  - 2 text to print
function echoColor()
{
    red="\e[0;91m"
    blue="\e[0;94m"
    green="\e[0;92m"
    yellow="\e[0;33m"
    reset="\e[0m"

    OPTIONFLAG=""
    
    case $1 in
        -n)
            OPTIONFLAG=-n
            shift
        ;;
    esac

    case $1 in
        r)
            echo $OPTIONFLAG -e $red$2$reset
        ;;
        b)
            echo $OPTIONFLAG -e $blue$2$reset
        ;;
        g)
            echo $OPTIONFLAG -e $green$2$reset
        ;;
        y)
            echo $OPTIONFLAG -e $yellow$2$reset
        ;;
    esac
}

TOOL_CHOICE=$(grep -oP '(?<=TOOL_CHOICE=).*' config.txt ) 

#Input variables for the script, these remain constant through the script execution
INPUT_SIZES=$(grep -oP '(?<=INPUT_SIZES=).*' config.txt ) 
echo -n "Tests will be done on input sizes : " 
echoColor b "$INPUT_SIZES"

SOURCE_DIRECTORY_MALWARE=$(grep -oP '(?<=SOURCE_DIRECTORY_MALWARE=).*' config.txt ) 
echo -n "Source directory for malware apks : "
echoColor b $SOURCE_DIRECTORY_MALWARE 

SOURCE_DIRECTORY_BENIGN=$(grep -oP '(?<=SOURCE_DIRECTORY_BENIGN=).*' config.txt ) 
echo -n "Source directory for BENIGN apks : "
echoColor b $SOURCE_DIRECTORY_BENIGN 

CURATED_APK_DIRECTORY=$(grep -oP '(?<=CURATED_APK_DIRECTORY=).*' config.txt ) 
echo -n "Destination directory for curated apks : "
echoColor b $CURATED_APK_DIRECTORY 

DESTINATION_DIRECTORY=$(grep -oP '(?<=DESTINATION_DIRECTORY=).*' config.txt ) 
echo -n "Destination directory for traces : "
echoColor b $DESTINATION_DIRECTORY 

REPACKAGED_PAIRS_FILE=$(grep -oP '(?<=REPACKAGED_PAIRS_FILE=).*' config.txt ) 
echo -n "Source for adding pair comparisons : "
echoColor b $REPACKAGED_PAIRS_FILE 

TIMEOUT_DELAY=$(grep -oP '(?<=TIMEOUT_DELAY=).*' config.txt ) 
echo -n "Maximum time allowed to test an apk : "
echoColor b $TIMEOUT_DELAY 

STRACE_ARGS=$(grep -oP '(?<=STRACE_ARGS=).*' config.txt ) 
echo -n "Strace arguments :  "
echoColor b "$STRACE_ARGS "


if [ ! -f $REPACKAGED_PAIRS_FILE ]
then
    echo -n "Source file "
    echoColor -n y "not found "
    echo "continuing without checking for repackaging ... "
fi

#main function body
function mainBody()
{
	
    prepareData

    processData

    exitScript
}

#prepares the data by creating UPIs and filling fileCorrespondance.csv accordingly
#this will fill CURATED_APK_DIRECTORY
function prepareData()
{
    echo
    echo "Preparing data ..."
    echo
    createDatabaseIfNeeded
    if [ ! -d $CURATED_APK_DIRECTORY ]
    then
        mkdir $CURATED_APK_DIRECTORY
    fi
    for LOCALDIR in $SOURCE_DIRECTORY_MALWARE/*/ $SOURCE_DIRECTORY_BENIGN/*/
    do
        [ -d "$LOCALDIR" ] || break #these guards are important in case folders are empty or don't exist
        echo -n "Preparing data in folder "
        echoColor -n b "$LOCALDIR ... "
        for FILE in $LOCALDIR*
        do
            [ -f "$FILE" ] || break
            #we start by hashing the file
            HASH=$(sha256sum $FILE | grep -oh "^[0-9A-Za-z]*")
            #if the file already exists we don't write further
            if [ ! -f $CURATED_APK_DIRECTORY/$HASH.apk ]
            then
                cp $FILE $CURATED_APK_DIRECTORY/$HASH.apk
            fi
            #we need to extract the apk data if necessary
            TMPSTR=$(grep "$HASH;" $DESTINATION_DIRECTORY/packageInfo.csv)
            if [ -z "$TMPSTR" ]
            then
                TMPSTR=$(echo $LOCALDIR | grep "$SOURCE_DIRECTORY_BENIGN" )
                if [ ! -z $TMPSTR ]
                then
                    extractAPKDataIntoDB $CURATED_APK_DIRECTORY/$HASH.apk $HASH 0
                else
                    extractAPKDataIntoDB $CURATED_APK_DIRECTORY/$HASH.apk $HASH 1
                fi
            fi
            #we need to add the file/UPI correspondance to the table
            SOURCENAME="${LOCALDIR%"${LOCALDIR##*[!/]}"}"
            SOURCENAME="${SOURCENAME##*/}"
            TMPSTR=$(grep "$FILE;" $DESTINATION_DIRECTORY/fileCorrespondance.csv)
            if [ -z "$TMPSTR" ]
            then
                echo "$FILE;$HASH;$SOURCENAME;" >> $DESTINATION_DIRECTORY/fileCorrespondance.csv
            fi
        done
        echoColor g "done"
    done
    echo
    echo -n "... preparing data "
    echoColor g "done"
}

#extracts the data to fill packageInfo.csv
#args :
# 1 filepath
# 2 hash
# 3 malware
function extractAPKDataIntoDB()
{
    #we create a tmp file buffer with the apk dump
    aapt dump badging $1 > $DESTINATION_DIRECTORY/~tmp.dump

    BUFFSTRING=""

    BUFFSTRING+="$2;"
    BUFFSTRING+="$3;"
    #we extract the package name
    EXTRACTSTRING=$(grep -Po package:\ "name='\K.*?(?=')" $DESTINATION_DIRECTORY/~tmp.dump)
    BUFFSTRING+="$EXTRACTSTRING;"

    #we extract the sdk version
    EXTRACTSTRING=$(grep -Po "sdkVersion:'\K.*?(?=')" $DESTINATION_DIRECTORY/~tmp.dump)
    if [ -n "$EXTRACTSTRING" ]
    then
        BUFFSTRING+="$EXTRACTSTRING;"
    else
        BUFFSTRING+="0;"
    fi

    #we extract the target sdk version
    EXTRACTSTRING=$(grep -Po "targetSdkVersion:'\K.*?(?=')" $DESTINATION_DIRECTORY/~tmp.dump)
    if [ -n "$EXTRACTSTRING" ]
    then
        BUFFSTRING+="$EXTRACTSTRING;"
    else
        BUFFSTRING+="0;"
    fi

    #we extract the application label
    EXTRACTSTRING=$(grep -Po "application-label:'\K.*?(?=')" $DESTINATION_DIRECTORY/~tmp.dump)
    if [ -n "$EXTRACTSTRING" ]
    then
        BUFFSTRING+="$EXTRACTSTRING;"
    else
        BUFFSTRING+="0;"
    fi

    #we check wether this is a repackaged apk from the pair table
    if [ -f $REPACKAGED_PAIRS_FILE ]
    then
        EXTRACTSTRING=$(grep -Po "[0-9A-Z]*?(?=,$2)" $REPACKAGED_PAIRS_FILE)
        if [ -n "$EXTRACTSTRING" ]
        then
            BUFFSTRING+="1;$EXTRACTSTRING;"
        else
            BUFFSTRING+="0;0;"
        fi
    else
        BUFFSTRING+="0;0;"
    fi

    #we extract all the permissions
    for PERM in $(cat permissions.txt)
    do 
        TMPSTR=$(grep $PERM $DESTINATION_DIRECTORY/~tmp.dump)
        if [ -n "$TMPSTR" ]
        then
            BUFFSTRING+="1;"
        else
            BUFFSTRING+="0;"
        fi
    done

    #we extract all the features
    for PERM in $(cat features.txt)
    do 
        TMPSTR=$(grep $PERM $DESTINATION_DIRECTORY/~tmp.dump)
        if [ -n "$TMPSTR" ]
        then
            BUFFSTRING+="1;"
        else
            BUFFSTRING+="0;"
        fi
    done


    echo $BUFFSTRING "" >> $DESTINATION_DIRECTORY/packageInfo.csv

    rm $DESTINATION_DIRECTORY/~tmp.dump
}

#starts the tracing proper
function processData()
{
    echo "Testing apks ... "
    echo
    for APK in $CURATED_APK_DIRECTORY/*.apk 
    do
        [ -f "$APK" ] || break
        echo -n "Starting tests for apk : "
        echoColor b "$APK ..."
        for INPUTNUMBER in $INPUT_SIZES 
        do
            echo -n "Test $INPUTNUMBER ... "
            if checkFiles "$APK" $INPUTNUMBER
            then
            	echo "l. 253"
                echoColor y skipped
                continue
            fi
	
		echo "l. 258"
            export -f createContainer traceAPK killContainer createContainerAndTrace echoColor
            echo "l. 260"
            export DESTINATION_DIRECTORY APK INPUTNUMBER STRACE_ARGS
            echo "l.262"
            timeout --foreground $TIMEOUT_DELAY  bash -c createContainerAndTrace
            echo "l. 264"
            TIMEOUTRETURN=$?

            addToDatabase "$APK" $INPUTNUMBER $TIMEOUTRETURN
            docker stop android-container > /dev/null
            docker rm android-container > /dev/null

        done
    done
    echo
    echo -n "... testing "
    echoColor g "done"
    echo
}

#proper exit function 
function exitScript()
{
    if [ -f $DESTINATION_DIRECTORY/~tmp.dump ]
    then
        rm $DESTINATION_DIRECTORY/~tmp.dump
    fi
    killContainer
    echo "Exiting properly"
    exit
}

#This creates the database files if none exist
function createDatabaseIfNeeded()
{
    if [ ! -e "$DESTINATION_DIRECTORY/packageInfo.csv" ] 
    then 
        echoColor -n y "Warning : preparing data - no existing database detected, creating ..."
        touch $DESTINATION_DIRECTORY/fileCorrespondance.csv
        touch $DESTINATION_DIRECTORY/packageInfo.csv
        touch $DESTINATION_DIRECTORY/logsCorrespondance.csv
        echo "sourceFileRelativeToScript;UPI;source;" > $DESTINATION_DIRECTORY/fileCorrespondance.csv
        echo "UPI;monkeyInputSize;eventsActuallySent;timedOut;monkeySeed;outFilesName;" > $DESTINATION_DIRECTORY/logsCorrespondance.csv
        echo -n "UPI;malware;packageName;sdkVersion;targetSDKVersion;applicationLabel;repackaged;identifiableSource;" > $DESTINATION_DIRECTORY/packageInfo.csv
        while read -r line || [[ -n "$line" ]]; do
            echo -n "$line;" >> $DESTINATION_DIRECTORY/packageInfo.csv
        done < permissions.txt
        while read -r line || [[ -n "$line" ]]; do
            echo -n "$line;" >> $DESTINATION_DIRECTORY/packageInfo.csv
        done < features.txt
        echo "" >> $DESTINATION_DIRECTORY/packageInfo.csv
        echoColor g " done"
    fi 
}

#terminates and deletes the container if applicable
function killContainer()
{
    echo
    DOCKSTATUS=$(docker ps | grep "android-container")
    if [ -z "$DOCKSTATUS" ]

    then
        DOCKSTATUS=$(docker ps -a | grep "android-container")
        if [ ! -z "$DOCKSTATUS" ]
        then
            echoColor -n y "Container remnant detecting, erasing ... "
            docker rm android-container
            echo g "erased"
        fi
    else
        echoColor -n y "Running container detected, shutting it down and erasing ... "
        docker stop android-container > /dev/null
        docker rm android-container > /dev/null
        echoColor g "erased"
    fi
}


#Checks if we should run a test for the apk given as an argument for the input size given as argument, considering the state of the database
#args :
# 1 the apk file to check
# 2 the size of the input
#return : 0 if no calculation is needed, 1 otherwise
function checkFiles()
{
    LOCALHASH=$(basename $1 .apk)
    #Checks if the apk is in the database, if not we have a problem
    TMPSTR=$(grep $LOCALHASH $DESTINATION_DIRECTORY/packageInfo.csv)
    if [ -z "$TMPSTR" ]
    then
        echo "Error, apk info not found in database for $1"
        return 0
    fi
    #If the SHA256 is in the database we need to check if a test with the request input size was done
    TMPSTR=$(grep "$LOCALHASH;$2;" $DESTINATION_DIRECTORY/logsCorrespondance.csv)
    if [ -z $TMPSTR ]
    then 
        return 1
    else
        return 0
    fi
}

# creates a container, pulling the google image if required, and then waits for the emulated device to finish booting
# this sets CONTAINERIP
function createContainer()
{
    killContainer
    docker run -d \
        -e ADBKEY="$(cat ~/.android/adbkey)" \
        --device /dev/kvm \
        --publish 8554:8554/tcp \
        --publish 5555:5555/tcp  \
        --name android-container \
        us-docker.pkg.dev/android-emulator-268719/images/30-google-x64:30.1.2 > /dev/null
    CONTAINERIP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' android-container)
    sleep 5
    adb connect $CONTAINERIP:5555 > /dev/null
    adb -s $CONTAINERIP:5555 wait-for-device > /dev/null

    while [ "$(adb -s $CONTAINERIP:5555 shell getprop sys.boot_completed | tr -d '\r')" != "1" ]; do
        echoColor -n y "Still waiting for boot"
        echo  " retrying in 10 sc ... "
        sleep 10
    done
}

function traceAPK()
{
    if [ "$TOOL_CHOICE" = 1 ]
    then
        echo "You chose to continue with Monkey"
    	traceAPKMonkey $1 $2 $3
    elif [ "$TOOL_CHOICE" = 2 ]
    then
    	echo "You chose to continue with DroidBot"
    	traceAPKDroidbot $1 $2 $3
    else 
    	echoColor r "erreur sur le choix de l'outil"
    fi
}

#args :
# 1 - apk to trace
# 2 - input events to do
# 3 - IP of the container
function traceAPKMonkey()
{
    LOCALHASH=$(basename $1 .apk)
    PACKNAME=$(aapt dump badging "$1" | grep -Po package:\ "name='\K.*?(?=')")

    echo -n "Installing apk via adb ... "
    adb -s $3:5555 install -g "$1" 
    
    echo -n "Tracing ... "
    adb -s $3:5555 shell strace $STRACE_ARGS /system/bin/sh /system/bin/monkey -p $PACKNAME -v $2  >$DESTINATION_DIRECTORY/$2-$LOCALHASH.monkdata 2>$DESTINATION_DIRECTORY/$2-$LOCALHASH.trace
    echoColor g "done"
}

#args :
# 1 - apk to trace
# 2 - input events to do
# 3 - IP of the container
function traceAPKDroidbot()
{
	echo -n "Preparing trace with droidbot..."
	sudo droidbot -a $1 -d $3:5555 -o output_dir -count $2 -keep_env -is_emulator
	moveOutput
	echocolor g "done"
}

function moveOutput()
{
	to_move=./output_dir/logcat.txt
	mv to_move $DESTINATION_DIRECTORY
	sudo rm -r ./output_dir/
}


#a wrapper for the functions createContainer and traceAPK
#args
# 1-APK
# 2-Input size
function createContainerAndTrace()
{
    createContainer

    traceAPK "$APK" $INPUTNUMBER $CONTAINERIP

    return 0
}

#adds the current apk to the database, using OUTFILENAME
#args
# 1-APK
# 2-Input size
# 3-timeout return value
function addToDatabase()
{
    LOCALHASH=$(basename $1 .apk)
    MONKEYSEED=0
    if [ $3 -eq 0 ]
    then 
        TIMEOUTAPPEND=0
        if [ ! -f $DESTINATION_DIRECTORY/$2-$LOCALHASH.monkdata ]
        then
            REALEVENTSEND=0
            TIMEOUTAPPEND=1
        else
            REALEVENTSEND=$(grep -Po "Events\ injected:\ \K.*" $DESTINATION_DIRECTORY/$2-$LOCALHASH.monkdata)
            if [ -z $REALEVENTSEND ]
            then 
                REALEVENTSEND=0
            fi
            MONKEYSEED=$(grep -Po ":Monkey: seed=\K[0-9]*?(?=\ )" $DESTINATION_DIRECTORY/$2-$LOCALHASH.monkdata)
        fi
    else
        REALEVENTSEND=0
        TIMEOUTAPPEND=1
    fi
    echo "$LOCALHASH;$2;$REALEVENTSEND;$TIMEOUTAPPEND;$MONKEYSEED;$2-$LOCALHASH;" >> $DESTINATION_DIRECTORY/logsCorrespondance.csv
}

mainBody
