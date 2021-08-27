#!/bin/bash
# Fred Denis -- July 2021 -- rac-on_all_db.sh re writing
# Execute a SQL or a Shell script or command line into a DB environment across a cluster
# --help for more information
#
set -o pipefail
#
# Variables
#
         TS="date "+%Y-%m-%d_%H%M%S""                                        # A timestamp for a nice outut in a logfile
    LOGFILE=$(mktemp)                                                        # A logfile
       TEMP=$(mktemp -u)                                                     # A tempfile
      TEMP2=$(mktemp -u)                                                     # Another tempfile
   TGT_TEMP=$(mktemp -u)                                                     # Another tempfile
     ORACLE="oracle"                                                         # User to sudo if started as root
        OLR="/etc/oracle/olr.loc"                                            # olr file to set up crs env
       GREP="."
     UNGREP="donotgrepme$$"
  REBALANCE="False"                                                          # Run the rebalance script to relocate the services to preferred nodes
REBALANCESH="./service_mgmt.sh -d {{ DB_U }} -b -D &"   # Rebalance script
exec &> >(tee -a "${LOGFILE}")
declare -A copiedfiles                     # Array to store the temporary files we have copied (for cleanup)
#
# Cleanup on exit
#
cleanup() {
    err=$?
    rm -f "${TEMP}" "${LOGFILE}" "${TGT_TEMP}" "${TEMP2}"

    if (( ${#copiedfiles[@]} > 0 )); then
        printf "\033[1;36m%s\033[m\n" "$($TS) [INFO] Cleaning up tempfiles"
        for uh in ${!copiedfiles[@]}; do
            HOST=$(echo ${uh} | awk -F ":" '{print $2}')
            su - "${ORACLE}" << END_SU
                ssh -qt -o StrictHostKeyChecking=no -o BatchMode=yes "${ORACLE}"@"${HOST}" rm -f "${copiedfiles[${uh}]}"
END_SU
        done
    fi

    exit ${err}
}
sig_cleanup() {
    printf "\033[1;31m%s\033[m\n" "$($TS) [ERROR] I have been killed !" >&2
    exit 666
}
trap     cleanup EXIT
trap sig_cleanup INT TERM QUIT
#
# Usage function
#
usage() {
    printf "\n\033[1;37m%-8s\033[m\n" "NAME"                ;
    cat << END
        $(basename $0) - Execute a SQL or a Shell script or command line into a DB environment across a cluster
END

    printf "\n\033[1;37m%-8s\033[m\n" "SYNOPSIS"            ;
    cat << END
        $0 [--sql] [--sh] [--grep] [--ungrep] [--relocate] [--help]
END

    printf "\n\033[1;37m%-8s\033[m\n" "DESCRIPTION"         ;
    cat << END
        - Get the DB names and their environment in an Oracle cluster (crsctl is used); --grep and --ungrep values applies to this list
        - ssh to the first node where a database has an instance Open and:
          - if --sql is used then sqlplus / as sysdba and execute the SQL script/command line
          - if --sh  is used then execute the shell script/command line in the instance environment (OH and SID)
        - Databases with no running instancs are skipped with a warning
        - If the parameter of --sql or --sh is not a file, it is considered being a command line and will be executed as such
        - Only one script/command line can be executed so if --sql AND --sh are specified on the command line, --sql wins
        - If you want to execute many scripts, call this script many times or make a script of it
        - If you want to execute many command lines, make it a script and execute it
        - --relocate is a special option automatically executing ${REBALANCESH}
        - Some "jinja-like "variables can be used to be dynamically replaced (see examples for more on this):
          - {{ DB_U }} => DB name in upper case
          - {{ DB_L }} => DB name in lower case
          - {{ SID }}  => ORACLE_SID
          - {{ OH }}   => ORACLE_HOME
        - Above variables are supported in command lines and scripts
END

    printf "\n\033[1;37m%-8s\033[m\n" "OPTIONS"             ;
    cat << END
        --sql            ) A SQL file to run, if this is not a file, it is used as command lines to run
        --shell | --sh   ) A shell script to run, if this is not a file, it is used as command lines to run
        -g | --grep      ) grep databases names to run the scripts against
        -v | --ungrep    ) acts as a "grep -v" against the database names
        -r | --relocate  ) Execute the shell script ${REBALANCESH}

        -h | --help      ) Shows this help
END

    printf "\n\033[1;37m%-8s\033[m\n" "EXAMPLES"            ;
    cat << END
        $0 --sql "status.sql"                              # Run status.sql on an instance of each DB
        $0 --sql "status.sql" --grep prod                  # Run status.sql on an instance of each DB containing "prod" in their names
        $0 --sql "status.sql" --grep prod --ungrep app     # Run status.sql on an instance of each DB containing "prod" in their names but not "app"
        $0 --sh "ls.sh" --grep prod --ungrep app           # Run ls.sh on an instance environment for each DB containing "prod" in their names but not "app"
        $0 --sql "show user"                               # Run "show user" on an instance of each DB
        $0 --sh "ps -ef | grep pmon_{{ SID }}"             # {{ SID }} will be dynamically replaced to execute this ps
        $0 --sh "do_something.sh -d {{ DB_U }}"            # Will execute do_something.sh with the correct DB name in upper case on each environement
        $0 --relocate                                      # Run ${REBALANCESH}

END
exit 999
}
#
# Replace {{ variables }} with values in the script options
#
replace_variables() {
    IN=$1

    if [[ -f "${IN}" ]]; then   # If a file, we replace in the file
        sed -i -e 's/{{ */{{/g' -e 's/ *}}/}}/g' "${IN}"
        sed -i -e "s/{{DB_U}}/${DB_U}/g" -e "s/{{DB_L}}/${DB_L}/g" -e "s/{{SID}}/${SID}/g" -e "s#{{OH}}#${OH}#g" "${IN}"
    else
        if [[ -z "${IN}" ]]; then
            echo ""
        else
            IN=$(echo ${IN} | sed s'/{{ */{{/g' | sed s'/ *}}/}}/g')     # Remove blanks to allow {{VAR}} or {{   VAR }} syntax
            IN=$(echo ${IN} | sed s"/{{DB_U}}/${DB_U}/g")                # DB upper case
            IN=$(echo ${IN} | sed s"/{{DB_L}}/${DB_L}/g")                # DB upper case
            IN=$(echo ${IN} | sed s"/{{SID}}/${SID}/g")                  # ORACLE_SID
            IN=$(echo ${IN} | sed s"#{{OH}}#${OH}#g")                    # ORACLE_HOME
            echo "${IN}"
        fi
    fi
}
#
# Options -- Long and Short, options needs to be separa
# Options are comma separated list, options requiring a parameter need to be followed by a ":"
#
SHORT="g:,v:,r,h"
 LONG="sql:,shell:,sh:,grep:,ungrep:,relocate,help"
# Check if the specified options are good
options=$(getopt -a --longoptions "${LONG}" --options "${SHORT}" -n "$0" -- "$@")
# If not, show the usage and exit
if [[ $? -ne 0 ]]; then
    printf "\033[1;31m%s\033[m\n" "$($TS) [ERROR] Invalid options provided: $*; use -h for help; cannot continue." >&2
    exit 864
fi
#
eval set -- "${options}"
# Option management, not the "shift 2" when an option requires a parameter and "shift" when no parameter needed
while true; do
    case "$1" in
        --sql            )       SQL="$2"                  ; shift 2 ;;
        --shell | --sh   )      SHWO="$2"                  ; shift 2 ;;
        -g | --grep      )      GREP="$2"                  ; shift 2 ;;
        -v | --ungrep    )    UNGREP="$2"                  ; shift 2 ;;
        -r | --relocate  ) REBALANCE="True"                ; shift   ;;
        -h | --help      ) usage                           ; shift   ;;
        --               ) shift                           ; break   ;;
    esac
done
#
# Options verification -- important to check that what is needed for the script is correctly provided
# SHWO = SH With Options
#   SH = SH script itself
# OPTS = SH options
#
if [[ "${REBALANCE}" == "True" ]]; then
    SHWO="${REBALANCESH}"
fi
if [[ -n "${SHWO}" ]]; then
    SH=$(echo ${SHWO} | awk '{print $1}')                      # Remove potential options to test if the script exists
    if [[ ! -f "${SH}" ]]; then
#        printf "\033[1;31m%s\033[m\n" "$($TS) [ERROR] cannot find ${SH}; cannot continue"
#        exit 123
         echo "${SHWO}" > "${TEMP2}"                           # Not a file ? so may be some command lines
         TOEXEC="${TEMP2}"
    else
          OPTS=$(echo ${SHWO} | awk '{$1=""; print $0}')       # Only the options of the script
        TOEXEC="${SH}"
    fi
    TYPE="SH"
fi
if [[ -n "${SQL}" ]]; then
    if [[ ! -f "${SQL}" ]]; then
        #printf "\033[1;31m%s\033[m\n" "$($TS) [ERROR] cannot find ${SQL}; cannot continue"
        #exit 124
        echo "${SQL}" > "${TEMP2}"                           # Not a file ? so may be some command lines
        TOEXEC="${TEMP2}"
    else
        TOEXEC="${SQL}"
    fi
    TYPE="SQL"
fi
if [[ -z "${SH}" && -z "${SQL}" ]]; then
    printf "\033[1;31m%s\033[m\n" "$($TS) [ERROR] A script to execute has to be specified; please use -h to see the available options."
    exit 125
fi
GROUP=$(id -gn ${ORACLE})
#
# Do things :)
#
export ORACLE_HOME=$(cat "${OLR}" | grep "^crs_home" | awk -F "=" '{print $2}')
export ORACLE_BASE=$(${ORACLE_HOME}/bin/orabase)
export        PATH="${PATH}:${ORACLE_HOME}/bin"
#. oraenv <<< +ASM1 > /dev/null 2>&1
for X in $((crsctl stat res -p -w "TYPE = ora.database.type"; crsctl stat res -w "TYPE = ora.database.type") | grep -E "^NAME=|GEN_USR_ORA_INST_NAME@SERVERNAME|STATE=|^ORACLE_HOME=|^$" | \
    awk -F "=" -v GREP="${GREP}" -v UNGREP="${UNGREP}" ' \
        { if ($1 == "NAME" && $2 ~ UNGREP) { next }
          if ($1 == "NAME" && $2 ~ GREP) {
              sub("^ora.", "", $2)                                      ;
              sub(".db$", "", $2)                                       ; # Remove the consumer group
              DB = $2                                                   ;
              tab_db[DB] = DB                                           ; # List of databases

              while(getline)
              {   if ($1 == "ORACLE_HOME") {
                      tab_oh[DB] = $2                                   ; # List of OH
                  }
                  if ($1 ~ /^GEN_USR_ORA_INST_NAME@SERVERNAME/) {
                      sub("GEN_USR_ORA_INST_NAME@SERVERNAME[(]", "", $1);
                      sub(")", "", $1)                                  ;
                      HOST = $1                                         ; # Host
                      SID  = $2                                         ; # SID
                      tab_sid[DB][HOST] = SID                           ; # We store SID / node
                  }
                  if ($1 == "STATE") {
                      if ($2 ~  /ONLINE/) {
                          n = split($2, temp, ", ")                     ;
                          for (i=1; i<=n; i++) {
                              split(temp[i], temp2, " ")                ;
                              if (temp2[1] == "ONLINE") {
                                  tab_online[DB] = temp2[3]             ;
                                  break                                 ;
                              }
                          }
                      }
                  }
                  if ($0 ~ /^$/){ break; }
              }
          }
        } END {
            for (x in tab_db) {
                printf("%s:", tab_db[x])                                ;   # DB
                printf("%s:", tab_oh[x])                                ;   # OH
                printf("%s:", tab_online[x])                            ;   # Host the SID is online on
                printf("%s" , tab_sid[x][tab_online[x]])                ;   # SID on above host
                printf("\n")                                            ;
            }
        }' | sort); do
        DB=$(echo "${X}" | awk -F ":" '{print $1}')
      DB_U=$(echo "${DB}"| tr '[:lower:]' '[:upper:]')                      # DB upper case (see replace_variables)
      DB_L=$(echo "${DB}"| tr '[:upper:]' '[:lower:]')                      # DB lower case (see replace_variables)
        OH=$(echo "${X}" | awk -F ":" '{print $2}')
      HOST=$(echo "${X}" | awk -F ":" '{print $3}')
       SID=$(echo "${X}" | awk -F ":" '{print $4}')

    if [[ -z "${HOST}" ]]; then
        printf "\033[1;33m%s\033[m\n" "$($TS) [WARNING] $DB is not running on any host, skipping it"
        continue
    fi

    # Shell script may contain options to be dymically replaced
    OPTS_REPLACED=$(replace_variables "${OPTS}")
    # A local copy for sudo user to deal with this file
    cp "${TOEXEC}" "${TEMP}"
    chown "${ORACLE}":${GROUP} "${TEMP}"
    replace_variables "${TEMP}"

#    cat "${TEMP}"
#    echo $SH
#    echo $SHWO
#    echo $OPTS
#    echo $SQL
#    echo $SH" "$OPTS
#    echo "Temp"${TEMP}
#    cat ${TEMP}
#    exit

    printf "\033[1;36m%s\033[m\n" "$($TS) [INFO] ${DB}@${HOST}"
    copiedfiles["${DB}@${HOST}"]="${TEMP}"
    su - "${ORACLE}" << END_SU
        scp -q -o StrictHostKeyChecking=no -o BatchMode=yes "${TEMP}" "${ORACLE}"@"${HOST}":"${TGT_TEMP}"
        if [ $? -ne 0 ]; then
            printf "\033[1;36m%s\033[m\n" "$($TS) [ERROR] Could not copy ${TEMP} to ${HOST}:${TGT_TEMP}; skipping ${DB}@${HOST}"
            continue
        fi
        ssh -qt -o StrictHostKeyChecking=no -o BatchMode=yes "${ORACLE}"@"${HOST}" << END_SSH
            export ORACLE_HOME="${OH}"
            export  ORACLE_SID="${SID}"
            export PATH=$PATH:${OH}/bin
            if [[ -f "${TGT_TEMP}" ]]; then
                if [[ "${TYPE}" == "SQL" ]]; then
                    sqlplus -S / as sysdba << END_SQL
                        @"${TGT_TEMP}"
END_SQL
                fi
                if [[ "${TYPE}" == "SH" ]]; then
                    #echo /bin/bash "${TGT_TEMP}" "${OPTS_REPLACED}"
                    . ${TGT_TEMP} ${OPTS_REPLACED}
                fi
                rm -f "${TGT_TEMP}"
            fi
END_SSH
END_SU
done

