#!/usr/bin/bash

# Version 0.1

# Fabio Pardi - Agileos Consulting 
# www.agileosconsulting.com 

# Please refer to the official docs on how to use this tool: https://github.com/dba-git/kafka_smart_rebalancer/

# The goal of this Kafka rebalancer is to distribute the partitions across the desired brokers to achieve balance
# The aim of this utility is to minimize the number of partition changes in order to move as less data as possible and do not stress the cluster's resources



# TODO

# * Print some info only in debug mode - replace | tee -a with $debug for the uninteresting lines
# * smarter executable assignment, to allow this to run on normal installations (not only K8s)
# * time how long it takes to add a broker VS kafka-reassign-partitions


RED='\033[0;31m'
NC='\033[0m' # No Color
tmp_dir=`date '+%Y%m%d%H%M'`
logfile=$tmp_dir/logfile


print_help(){
echo
echo "Welcome to the automagic Kafka rebalancer"
echo
echo "Use mode=auto to rebalance in case one or more brokers failed. Under Replicated Partitions will be rebalanced over the survived brokers"
echo
echo "Use mode=manual to add or remove a broker"
echo "Usage: $0  --mode=auto   --zookeeper=zoo:2181 --bootstrap-server=kafka:9092 [--debug]"
echo "NOTE: the list of brokers must be at least equal to the replication factor of your topics"
echo "Usage: $0  --mode=manual --zookeeper=zoo:2181 --bootstrap-server=kafka:9092 --brokers=0,1,2 [--debug]"
echo
exit 1
}


set_commands(){
echo -n "Assigning executables.............................  "
KAFKA_TOPICS="kafka-topics"
ZOOKEEPER_CLIENT="zookeeper-shell"
REASSIGN_PARTITIONS="kafka-reassign-partitions"
echo "OK! Executables are statically assigned"
}


check_connection() {
echo -n "Testing Zookeeper connection....................... " 
$ZOOKEEPER_CLIENT $zookeeper ls /brokers 2> /dev/null > $tmp_dir/zookeeper_smoketest
check_zoo=`grep "topics" $tmp_dir/zookeeper_smoketest | wc -l`

if [ -f $tmp_dir/zookeeper_smoketest ] && [ $check_zoo -eq 1 ] 
then
	echo "OK! Zookeeper is responding"
	rm -f $tmp_dir/zookeeper_smoketest
else
	echo -e "${RED}Cannot connect to zookeeper using to $zookeeper. Bailing out!${NC}"
	exit 1 
fi

if [ "x$bootstrap" == "x"  ]
then
	print_help
fi

echo -n "Testing Kafka connection........................... "
$KAFKA_TOPICS --list --bootstrap-server $bootstrap &> /dev/null || { echo -e "${RED}Cannot query Kafka server ${bootstrap} ${NC}" ; exit 1 ; }
echo "OK! Kafka is responding"
}



############# Action here below


start_manual(){
	# This command generates a full list of topics and their partitions
	$KAFKA_TOPICS --describe --bootstrap-server $bootstrap | grep -v "TopicId:" > $tmp_dir/topics_partitions_to_process
    find_target_brokers
	generate_list_of_topics_to_rebalance
	if [ "$action" == "remove" ]
	then
		generate_remove_proposal
	else
		generate_add_proposal
	fi
}


start_auto(){
	$KAFKA_TOPICS --describe --bootstrap-server $bootstrap --under-replicated-partitions | grep -v "TopicId:" > $tmp_dir/topics_partitions_to_process
	find_under_replicated_partitions
	find_offline_brokers
	generate_remove_proposal
}


try_candidate(){
    candidate=$1
    replicas=$2
    echo -n "Trying broker $candidate on replicas $replicas.... " >> $logfile
    echo "$replicas" | grep -q "^${candidate}\|,${candidate}\|${candidate}$"
    if [ $? -eq 0 ]
    then
        # Collision detected
        echo  "NOK! Broker $candidate is already present on Replicas list, skipping.." >> $logfile
        return 1
    else
        echo "OK! Broker $candidate can replace $broker_to_add_or_remove" >> $logfile
        return 0
    fi
}

find_under_replicated_partitions(){
	lines=`cat $tmp_dir/topics_partitions_to_process | awk -F ":" '{print $2}' | awk '{print $1}' | uniq | wc -l`
	if [ $lines = 0 ]
	then
	    echo -e "${RED}No partitions found in the rebalance list ${NC}"
	    exit 1
	fi
}


find_target_brokers(){
	echo -n "Identifying target brokers to add/remove........... "
	# This creates a column with all the brokers assigned over all the current partitions
    more $tmp_dir/topics_partitions_to_process | awk '{print $8}' | sed 's/\(,\)/\n/g' | sort | uniq > $tmp_dir/brokers_in_describe_output

    more $tmp_dir/brokers_list | sed 's/ /\n/g' | sort | uniq > $tmp_dir/brokers_column
	
	if [ `more $tmp_dir/brokers_column | wc -l` -lt `more $tmp_dir/brokers_in_describe_output | wc -l` ]
	then
	    # Create a diff: identify the brokers to remove from the cluster 
    	comm -23 $tmp_dir/brokers_in_describe_output $tmp_dir/brokers_column  > $tmp_dir/target_brokers
		echo "OK! Brokers to remove from the cluster are recorded in file $tmp_dir/target_brokers (id: `cat $tmp_dir/target_brokers | tr '\n' ' '`)"
		action=remove
	else
		if [ `more $tmp_dir/brokers_column | wc -l` -eq `more $tmp_dir/brokers_in_describe_output | wc -l` ]
		then
			echo -e "${RED}NOK! List of brokers passed by command line is = to list of brokers seen in the current partitions distribution! (`more $tmp_dir/brokers_column | wc -l`)${NC}"
			exit 1
		else
		    # Create a diff: identify the brokers to add to the cluster 
    		comm -23 $tmp_dir/brokers_column $tmp_dir/brokers_in_describe_output  > $tmp_dir/target_brokers
			echo "OK! Brokers to add to the cluster are recorded in file $tmp_dir/target_brokers (id: `cat $tmp_dir/target_brokers | tr '\n' ' '`)"
			action=add
		fi
	fi

	# Commented out for debug
    #rm -f $tmp_dir/brokers_in_describe_output 
    #rm -f $tmp_dir/brokers_column

}



find_offline_brokers(){
	echo -n "Identifying offline brokers........................ "

    # Parse all topics-partitions in search of brokers currently not available (how? the difference between the assigned list of 'replicas' and the actual ISR)
	while read -r line
	do
	    echo $line | awk '{print $8}' | sed 's/\(,\)/\n/g' | sort > $tmp_dir/brokers_in_describe_output
	    echo $line | awk '{print $10}' | sed 's/\(,\)/\n/g' | sort > $tmp_dir/isr_file
	    comm -23 $tmp_dir/brokers_in_describe_output $tmp_dir/isr_file >> $tmp_dir/target_brokers_tmp
	    rm $tmp_dir/brokers_in_describe_output
	    rm $tmp_dir/isr_file
	done < $tmp_dir/topics_partitions_to_process

	more $tmp_dir/target_brokers_tmp | sort | uniq > $tmp_dir/target_brokers
	rm -f $tmp_dir/target_brokers_tmp

	echo "OK! Offline brokers recorded in file $tmp_dir/target_brokers (brokers: `cat $tmp_dir/target_brokers | tr '\n' ' '`)"
}


generate_alive_brokers_list(){
if [ "x$brokers" == "x" ]
then
    echo -n "Brokers list not passed, fetching available brokers "
    $ZOOKEEPER_CLIENT  $zookeeper ls /brokers/ids 2>/dev/null > $tmp_dir/brokers
    cat $tmp_dir/brokers | tail -1 |tr -d "[]" | tr -d ' ' | sed 's/,/ /g' > $tmp_dir/brokers_list
	# Comma separated list, used to feed kafka-reassign-partitions utility 
    brokers=`cat $tmp_dir/brokers | tail -1 |tr -d "[]" | tr -d ' ' `

fi

if [ ! -s $tmp_dir/brokers ]
then
    echo -e "${RED}NOK! I was not able to retrieve brokers list. Bailing out!${NC}"
    exit 1
else
    echo "OK! Distributing partitions over brokers $brokers"
fi
}


generate_list_of_topics_to_rebalance(){
	echo -n "Creating JSON file................................. "
	echo "{\"topics\": [" > $tmp_dir/topics_list.json
	i=0
    lines=`cat $tmp_dir/topics_partitions_to_process | awk -F ":" '{print $2}' | awk '{print $1}' | uniq | wc -l`
	for topic in `cat $tmp_dir/topics_partitions_to_process | awk -F ":" '{print $2}' | awk '{print $1}' | uniq`
	do
	    ((i=i+1))
	    if [ $i = $lines ];then
	        echo "{\"topic\": \"$topic\"}" >> $tmp_dir/topics_list.json
	    else
	        echo "{\"topic\": \"$topic\"}," >> $tmp_dir/topics_list.json
	    fi
	done

	echo "]," >> $tmp_dir/topics_list.json
	echo "\"version\":1 }" >> $tmp_dir/topics_list.json
	echo "OK! Existing layout saved to file kafka_layout_pre_balancing"


    echo -n "Retrieving current partitions layout............... "
    $REASSIGN_PARTITIONS --bootstrap-server $bootstrap --broker-list $brokers --generate --topics-to-move-json-file $tmp_dir/topics_list.json > $tmp_dir/proposal.json
    head -2 $tmp_dir/proposal.json | tail -1 > $tmp_dir/current_layout.json && rm $tmp_dir/proposal.json
    echo "OK! Layout stored in $tmp_dir/current_layout.json"

    # Save current layout for debug purposes
    cp $tmp_dir/current_layout.json $tmp_dir/new_layout.json

}

generate_add_proposal() {

	# Add a new broker to the cluster avoiding collisions 
    # Eg: Suppose we have Replicas  4,0,7 and offline broker is 7, we need then to replace 7 with a broker different from 4 and 0

	# Algorithm:
    # To be iterated for each new broker:

    # For each topic in the list: 

	# counter=total number of partions * replica factor
	
	# until counter is not 0

    # Create a list of brokers assigned to all partitions on this topic 

    ## candidate = the broker with more partitions assigned in this topic. use this broker as candidate for replacement

	# Replace candidate with new broker
	# Remove partition from the list + decrease the counter of assigned partitions to new broker + decrease the counter of old broker

	# Count the topics with less partitions than total brokers. Assign to yourself one of them every (number_of_brokers) iterations
	skipped=0		

   	for broker_to_add_or_remove in `cat $tmp_dir/target_brokers`
	do

        echo " ###################################### "
        echo "  I m going to ${action} broker $broker_to_add_or_remove"
        echo " ###################################### "
        echo

		more $tmp_dir/topics_partitions_to_process | awk '{print $2}' | sort | uniq > $tmp_dir/all_topics_list
  	    for topic in `cat $tmp_dir/all_topics_list`
        do  
			echo 
			echo "**********************"
			echo "Processing topic $topic"	
			echo "**********************"

            # Create a list of the current topic-partitions
            cat $tmp_dir/topics_partitions_to_process | grep -P "$topic\t" > $tmp_dir/target_topic_partitions

			# Count the total number of partitions in the topic to account for how many should be reassigned
			total_partitions_in_topic=`more $tmp_dir/target_topic_partitions | grep -P "$topic\t" | awk '{print $8}' | sed 's/,/ /g' | wc -w`
			
			# Number of partitions to reassign = total_partitions / (brokers assigned to topic )
			brokers_assigned_to_topic=`more $tmp_dir/target_topic_partitions | grep -P "$topic\t" | awk '{print $8}' | sed 's/\(,\)/\n/g' | sort | uniq |wc -l`
			partitions_to_reassign=`echo $(($total_partitions_in_topic / ($brokers_assigned_to_topic + 1 )))`
			
			echo "I found $total_partitions_in_topic partitions and a total of $brokers_assigned_to_topic brokers assigned. I will assign $partitions_to_reassign partitions to the new broker"
			
			if [ $partitions_to_reassign -eq 0 ]
			then
				# Increase the counter
				skipped=`echo $(($skipped + $total_partitions_in_topic))`
				total_num_of_brokers=`more $tmp_dir/brokers_column | wc -l`
	            partitions_to_reassign=`echo $(($skipped / $total_num_of_brokers ))`
				if [ $partitions_to_reassign -eq 1 ]
				then
					echo "** Round robin assignment of topics with total replicas < total brokers **"
					skipped=`echo $(($skipped%$total_num_of_brokers))`
				fi
			fi
			

			while [ $partitions_to_reassign -gt 0 ]
			do
				# Parse all the partitions in the current topic to find the broker with more partitions assigned. This is the broker we are going to replace
				find_most_used_broker_on_a_topic
	            candidate=$(more $tmp_dir/most_used_broker)
				echo "Candidate is $candidate"
				rm -f $tmp_dir/most_used_broker

				while read -r topic_partition 
				do
	                replicas=`echo $topic_partition | awk '{print $8}'`
	                partition=`echo $topic_partition | awk '{print $4}'`
					echo "Parsing topic $topic - partition $partition "	

                	# Is the candidate broker present in the line we are processing? yes: proceed else skip
                	echo  "$replicas" | grep -q  "^${candidate}\|,${candidate}\|${candidate}$"
                	if [ $? -eq 0 ]
					then
						echo "*** Match! Candidate $candidate can be replaced on $replicas"
						# replace with candidate
		                replace_broker_with_candidate "$topic" "$partition" "$replicas"  "$candidate" "$broker_to_add_or_remove"

        	    	  	# Delete the line (topic - partition) from the list
						echo "Removing partition $partition from file $tmp_dir/target_topic_partitions"
						sed  -i "/Topic: $topic\tPartition: $partition\t.*/d" $tmp_dir/target_topic_partitions
	
						((partitions_to_reassign--))
						echo
						echo "-> Partitions left to reassign: $partitions_to_reassign"
						break
					else
						echo "No match for candidate $candidate on $replicas"
					fi
				done < $tmp_dir/target_topic_partitions
			done
        done 

	done
}

find_most_used_broker_on_a_topic(){
most_used_broker=0
partitions_amount=0

echo "Current partitions assignement for topic $topic"
for broker in `cat $tmp_dir/brokers_list`
do  
#	echo "Inspecting partitions assigned to broker $broker"
	assigned_partitions[$broker]=`more $tmp_dir/target_topic_partitions | grep -P "$topic\t" | awk '{print $8}' | grep  "^${broker}\|,${broker}\|${broker}$" | wc -l`
    echo  "Broker $broker: ${assigned_partitions[$broker]}"
done

# Randomize the order in order to avoid the first broker consistently being deprived of more partitions than the others
for broker in `cat $tmp_dir/brokers_list | sed 's/ /\n/g' |shuf`
do
	if [ ${assigned_partitions[$broker]} -gt $partitions_amount ]
	then
		most_used_broker=$broker
		partitions_amount=${assigned_partitions[$broker]}
	fi 
done
# Store result
echo $most_used_broker > $tmp_dir/most_used_broker
}


generate_remove_proposal() {
	# Replace the offline broker with a round robin over online brokers, avoiding collisions 
	# Eg: Suppose we have Replicas  4,0,7 and offline broker is 7, we need then to replace 7 with a broker different from 4 and 0

	# Algorithm:
	# To be iterated for each offline broker:
	# For each topic-partition in the list: 
	## candidate=pick from bench. If bench is empty, then pick from candidate_brokers_list_array

	# Broker assigned   ->  remove from array
	# Candidate in the list has no match? -> add to bench list (this way we guarantee all brokers get near-evenly assigned)
	# Empty or unusable bench, and empty list of candidates -> refill candidates (restore initial array)


    # Initial assignment: all brokers that will get assigned to partitions
    list_of_surviving_brokers_array=(`cat $tmp_dir/brokers_list`)

	for broker_to_add_or_remove in `cat $tmp_dir/target_brokers`
	do

		echo " ###################################### "
		echo "  I m going to ${action} broker $broker_to_add_or_remove"
		echo " ###################################### "
		echo
	
		# This array is used to keep track of the current candidates list. Brokers get removed from the list when they get a new partition assigned
		candidate_brokers_list_array=("${list_of_surviving_brokers_array[@]}")

		# This is the reserve array. Gets populated only when the only remaining brokers in candidate_brokers_list_array cannot be assigned due to collision. We then park those brokers on a side,to be used with priority at the next iterations
		candidate_brokers_on_bench_array=()

		echo
		while read -r line
		do
		    topic=`echo $line | awk '{print $2}'`
			partition=`echo $line | awk '{print $4}'`
			replicas=`echo $line | awk '{print $8}'`
			echo
			echo "Processing topic $topic on partition $partition replicas $replicas " | tee -a $logfile
	
    		# Is the offline broker present in the line we are processing? yes: proceed else skip
    		echo  "$replicas" | grep -q  "^${broker_to_add_or_remove}\|,${broker_to_add_or_remove}\|${broker_to_add_or_remove}$"
    		if [ $? -eq 0 ]
  		  	then
    		    assigned=0
    		    # Find the best candidate
    		    # Try first on the previously discarded ones (bench)
    		    bench_pos=0
    		    tmp_bench=("${candidate_brokers_on_bench_array[@]}")
    		    candidate_brokers_on_bench_array=()
    		    candidate_brokers_on_bench_array=("${tmp_bench[@]}")
		
				echo  "Processing bench list.......... " >> $logfile
	    	    for candidate in ${candidate_brokers_on_bench_array[@]}
    		    do
        		    try_candidate $candidate $replicas
        		    if [ $? -eq 0 ]
        		    then
    		            unset candidate_brokers_on_bench_array[$bench_pos]
    		            assigned=1
    		            break
    		       else
        		        ((bench_pos++))
        		    fi
        		done
				if [ $assigned -eq 0 ]
				then
	    	    	echo " Bench processed - no broker assigned from the bench" >> $logfile
				fi
		
		        # If the broker was not assigned from one in the bench, then use brokers list
		        while [ $assigned -eq 0 ]
		        do
		            if [ ${#candidate_brokers_list_array[@]} -eq 0 ]
		            then
		                # Refill the list
		                echo "List of candidate brokers is empty, refilling.." >> $logfile
	    	            candidate_brokers_list_array=("${list_of_surviving_brokers_array[@]}")
					else
		        	    echo "List of candidate brokers is [${candidate_brokers_list_array[@]}]" >> $logfile
	            	fi
		            # Position in the candidates array
		            cand_pos=0
		            # We need to reset arrays position. Maybe there is a better way to do so, but this is what i can do with my poor knowledge on arrays. Problem is that we iterate over a list, but the pointer (cand_pos) does not know where actually is the record we are working on
	    	        tmp_cand=("${candidate_brokers_list_array[@]}")
	        	    candidate_brokers_list_array=()
	        	    candidate_brokers_list_array=("${tmp_cand[@]}")
	        	    candidate_brokers_on_bench_array_lenght=${#candidate_brokers_list_array[@]}
	        	    for candidate in  ${candidate_brokers_list_array[@]}
	        	    do
	        	        echo "Candidates array lenght: $candidate_brokers_on_bench_array_lenght, candidate broker: $candidate (array position: $cand_pos)" >> $logfile
	        	        try_candidate $candidate $replicas
	        	        if [ $? -eq 0 ]
	            	    then
	            	        # echo "candidate fits, removing from list"
	            	        # remove candidate from candidate list
	            	        unset candidate_brokers_list_array[$cand_pos]
							echo "Remaining items in candidate_brokers_list_array ${candidate_brokers_list_array[@]}" >> $logfile
	                    	assigned=1
	                    	break
	                	else
	             	       ((cand_pos++))
	             	   fi
	            	if [ $candidate_brokers_on_bench_array_lenght -eq $cand_pos ]
	            	then
		                echo "No more possible brokers to try... moving existing brokers to the bench and refilling" >> $logfile
		                # We reached the end of the array, without possible candidates. move the brokers to the bench and refill
		                candidate_brokers_on_bench_array=("${candidate_brokers_list_array[@]}")
		                candidate_brokers_list_array=("${list_of_surviving_brokers_array[@]}")
		            fi
		            done
		
		            # we iterate over brokers in the brokers list
		            # if brokers list is empty, assign it with the full list
		        done
	   	
	    	else
	    	    echo "Line $line not matched " | tee -a  $logfile
	    	fi
	
		replace_broker_with_candidate "$topic" "$partition" "$replicas" "$broker_to_add_or_remove" "$candidate"
	
		done < $tmp_dir/topics_partitions_to_process

	done

	echo
	echo "*** New partitions layout ready! ***"
	echo
}


replace_broker_with_candidate(){
	topic_edit="$1"
	partition_edit="$2"
	replicas_edit="$3"
	broker_edit="$4"
	candidate_edit="$5"

	echo "I am going to replace ${broker_edit} with ${candidate_edit} on ${replicas_edit}" | >>  $logfile

	replicas_replaced=`echo "[${replicas_edit}]" | sed  "s/\[${broker_edit},/\[${candidate_edit},/g" | sed  "s/,${broker_edit},/,${candidate_edit},/g" | sed  "s/,${broker_edit}\]/,${candidate_edit}\]/g"`
	echo "Replacing replicas list [${replicas_edit}] with ${replicas_replaced}" | tee -a  $logfile


	to_replace="\"topic\":\"${topic_edit}\",\"partition\":${partition_edit},\"replicas\":\[${replicas_edit}\]"
	replace_with="\"topic\":\"${topic_edit}\",\"partition\":${partition_edit},\"replicas\":${replicas_replaced}"

	sed -i "s/$to_replace/$replace_with/g" $tmp_dir/new_layout.json
}


reassign_partitions() {
	echo -n "Reassigning Partitions based on $tmp_dir/new_layout.json... "
	$REASSIGN_PARTITIONS --bootstrap-server $bootstrap --execute --reassignment-json-file $tmp_dir/new_layout.json > /dev/null
	echo "OK! Rebalancing started."
	echo 
	echo "To check status, run:"
	echo $REASSIGN_PARTITIONS --bootstrap-server $bootstrap --verify --reassignment-json-file $tmp_dir/new_layout.json
}


echo  
echo "*********** Welcome to the automagic Least Effort Kafka rebalancer ************"
echo

echo -n "Setting up working dir............................. "
mkdir -p $tmp_dir || { echo -e "${RED}NOK! Problems creating $tmp_dir ${NC}" ; exit 1;}
echo "OK! working dir: $tmp_dir and logfile: $logfile"

mode="not_set"
debug=">"
for var in "$@";do
    case "$var" in
        --zookeeper=*)
            zookeeper="${var#*=}"
            ;;
        --bootstrap-server=*)
            bootstrap="${var#*=}"
            ;;
        --mode=*)
            mode="${var#*=}"
            ;;
        --brokers=*)
            brokers="${var#*=}"
            echo "${brokers[*]}" | sed 's/,/ /g' >  $tmp_dir/brokers_list
            ;;
		--debug)
			debug="| tee -a"
			;;
        *)
            print_help
            exit 1
    esac
done


if [ "$mode" == "manual" ] && [ "x$brokers" == "x" ]
then
    echo -e "${RED} Brokers list not passed! ${NC}"
    print_help
fi
 

set_commands
check_connection


case $mode in 
	auto)
		# If the list of online brokers is not provided, it will be then generated
		generate_alive_brokers_list
		start_auto
		;;
	manual)
		start_manual
		;;
	*)
		print_help
		;;
esac



reassign_partitions
