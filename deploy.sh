#!/bin/bash
#
# Speedy script to install Docker and Nvidia-Docker
# and deploy the RUBi code inside a PyTorch
# Docker container.
#
# ........................................................

set -e

DATADIR=data

#............................................................
#
# Installs the required packages (i.e. Docker and
#    nvidia-container-toolkit)
#
#............................................................
installPackages() {
    OLD_DIR=$PWD
    cd /tmp
    
    source /etc/os-release
    if [[ -z `command -v docker` ]]; then
        echo "Installing Docker"
        case $ID in
            arch)
                sudo pacman -Sy --needed --noconfirm docker
            ;;
            ubuntu|debian)
                sudo apt-get update
                sudo apt-get install -y \
                        apt-transport-https \
                        ca-certificates \
                        curl \
                        gnupg-agent \
                        software-properties-common
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
                sudo apt-key fingerprint 0EBFCD88
                sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
                sudo apt-get install -y docker-ce docker-ce-cli containerd.io
            ;;
        esac
    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker $USER
    fi

    if [[ -z `command -v axel` ]]; then
        echo "Installing Axel for faster downloads"
        case $ID in
            arch)
                sudo pacman -Sy --needed --noconfirm axel
            ;;
            ubuntu|debian)
                sudo apt-get update
                sudo apt-get install -y axel
            ;;
        esac
    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker $USER
    fi

    if [[ $GPU == "nvidia" ]]; then
    echo "Installing Nvidia-Docker and CUDA toolkit"
    case $ID in
        arch)
        sudo pacman -Sy --needed --noconfirm cuda
        
        git clone https://aur.archlinux.org/libnvidia-container.git
        cd libnvidia-container
        makepkg -sci --needed --noconfirm
        cd ..

        git clone https://aur.archlinux.org/nvidia-container-toolkit.git
        cd nvidia-container-toolkit
        makepkg -sci --needed --noconfirm
        cd ..

        rm -rf libnvidia-container nvidia-container-toolkit
        ;;
        ubuntu|debian)
        sudo apt install -y nvidia-cuda-toolkit nvidia-container-toolkit
        ;;
    esac
    sudo systemctl restart docker
    fi

    cd $OLD_DIR
}

#............................................................
#
# Parses command line arguments 
#
#............................................................
parseArguments() {
    # defaults
    GPU="none"
    REPO="antolu"
    BRANCH="master"

    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
        key="$1"

        case $key in
            --runtime)
                GPU="$2"
                shift # past argument
                shift # past value
                ;;
            -r|--repo)
                REPO="$2"
                shift # past argument
                shift # past value
                ;;
            -b|--branch)
                BRANCH="$2"
                shift # past argument
                shift # past value
            ;;
            --gcloud)
                GCLOUD=gcloud
                shift
            ;;
            --datasets)
                DATASETS=True
                shift
            ;;
            *)    # unknown option
                POSITIONAL+=("$1") # save it in an array for later
                shift # past argument
            ;;
        esac
    done

    if [[ $GPU == "none" && ! -z `lspci | grep -i nvidia` ]]; then
        GPU="nvidia"
    fi

}

#...........................................................
#
# Download the pretrained features and split them
#
#...........................................................
getVisualFeatures() {
    if [[ ! -d $DATADIR ]]; then
        mkdir -p $DATADIR
    fi
    
    cd $DATADIR

    if [[ ! -z $GCLOUD ]]; then
        echo "Downloading pretrained features from gcloud servers. Hold your beer."
        PROJECT_ID=`gcloud config list --format 'value(core.project)' 2>/dev/null`
        gsutil -u $PROJECT_ID cp gs://bottom-up-attention/trainval_36.zip ./ # 2014 Train/Val Image Features (120K / 25GB)
        gsutil -u $PROJECT_ID cp gs://bottom-up-attention/test2014_36.zip ./ # 2014 Testing Image Features (40K / 9GB)
    else
        echo "Downloading pretrained features from imagecaption. This might take a while..."
        curl -OL https://imagecaption.blob.core.windows.net/imagecaption/trainval_36.zip
        curl -OL https://imagecaption.blob.core.windows.net/imagecaption/test2014_36.zip
    fi

    unzip trainval_36.zip
    rm -f trainval_36.zip
    unzip test2014_36.zip
    rm -f test2014_36.zip

    cd ..
}

#...........................................................
#
# Split visual features into individual .pkl and .npz files
#
#..........................................................
splitVisualFeatures() {
    docker exec -it -w /home/RUBi -u $(id -u):$(id -g) tf-rubi bash -c "python2 tools/parse_visual_features.py data/trainval_36/trainval_resnet101_faster_rcnn_genome_36.tsv"
    docker exec -it -w /home/RUBi -u $(id -u):$(id -g) tf-rubi bash -c "python2 tools/parse_visual_features.py data/test2014_36/test2014_resnet101_faster_rcnn_genome_36.tsv"
}

#...........................................................
#
# Get VQA dataset
#
#..........................................................
getVQADataset() {
    echo "=> Getting the VQA dataset"

    if [[ ! -d $DATADIR ]]; then
        mkdir -p $DATADIR
    fi

    echo "Getting COCO"
    cd $DATADIR

    axel -qn20 http://images.cocodataset.org/zips/train2014.zip
    axel -qn20 http://images.cocodataset.org/zips/val2014.zip
    axel -qn20 http://images.cocodataset.org/zips/test2014.zip

    unzip train2014.zip
    rm -f train2014.zip
    unzip val2014.zip
    rm -f val2014.zip
    unzip test2014.zip
    rm -f test2014.zip

    echo "Getting VQA v2"
    mkdir vqa_v2
    cd vqa_v2
    axel -qn20 https://s3.amazonaws.com/cvmlp/vqa/mscoco/vqa/v2_Annotations_Train_mscoco.zip
    axel -qn20 https://s3.amazonaws.com/cvmlp/vqa/mscoco/vqa/v2_Questions_Train_mscoco.zip
    axel -qn20 https://s3.amazonaws.com/cvmlp/vqa/mscoco/vqa/v2_Annotations_Val_mscoco.zip
    axel -qn20 https://s3.amazonaws.com/cvmlp/vqa/mscoco/vqa/v2_Questions_Val_mscoco.zip
    axel -qn20 https://s3.amazonaws.com/cvmlp/vqa/mscoco/vqa/v2_Questions_Test_mscoco.zip

    cd ..

    unzip v2_Annotations_Train_mscoco.zip
    rm -f v2_Annotations_Train_mscoco.zip
    unzip v2_Questions_Train_mscoco.zip
    rm -f v2_Questions_Train_mscoco.zip
    unzip v2_Annotations_Val_mscoco.zip
    rm -f v2_Annotations_Val_mscoco.zip
    unzip v2_Questions_Val_mscoco.zip
    rm -f v2_Questions_Val_mscoco.zip
    unzip v2_Questions_Test_mscoco.zip
    rm -f v2_Questions_Test_mscoco.zip

    echo "Getting VQA-CP v2"
    mkdir -p vqacp_v2
    cd vqacp_v2
    axel -qn20 https://computing.ece.vt.edu/~aish/vqacp/vqacp_v2_train_annotations.json
    axel -qn20 https://computing.ece.vt.edu/~aish/vqacp/vqacp_v2_train_questions.json
    axel -qn20 https://computing.ece.vt.edu/~aish/vqacp/vqacp_v2_test_annotations.json
    axel -qn20 https://computing.ece.vt.edu/~aish/vqacp/vqacp_v2_test_questions.json

    cd ../..
}


#............................................................
#
# Checks whether Docker needs sudo permissions or nor
#
#............................................................
checkDockerPermissions() {
    set +e

    docker ps > /dev/null
    if [[ $? -ne 0 ]]; then
        echo -e "\n=> Docker seems to need sudo permissions. You probably need to log out from your user and log in again.\n"
        $SUDO="sudo "
    fi
    
    set -e
}

#............................................................
#
# Builds the Docker images containing TF and Caffe (and any
#    other packages specified in the Dockerfiles.
#
#............................................................
buildTFImage() {
    if [[ $GPU == "nvidia" && -z `docker images -q tf-gpu:latest` ]]; then
        $SUDO docker build --file ./Dockerfile/tf-gpu.Dockerfile -t tf-gpu:latest .
    elif [[ -z `docker images -q tf-cpu:latest` ]]; then
        $SUDO docker build --file ./Dockerfile/tf-cpu.Dockerfile -t tf-cpu:latest .
    fi
}

#............................................................
#
# Builds Docker image containing Pytorch and pip3 and any
#   other packages specified in the Dockerfile and
#   requirements.txt 
#
#............................................................
buildPyTorchImage() {
    $SUDO docker build --file ./Dockerfile/pytorch.Dockerfile -t pytorch-rubi --build-args GPU=$GPU.
}

#............................................................
#
# Removes the existing TF container (by name) to make room
#   for a new one.
#
#............................................................
removeTFContainer() {
    if [[ `docker ps | grep tf-rubi` != "" ]]; then
        echo "Stopping and removing existing container, press CTRL-C within 5 secs to cancel"
        for ((i=5; i>=1; i--)); do
            echo $i
            sleep 1
        done

        $SUDO docker stop tf-rubi
        $SUDO docker container rm tf-rubi
    fi
}

#............................................................
#
# Removes the existing Pytorch container (by name) to make room
#   for a new one.
#
#............................................................
removePyTorchContainer() {
    if [[ `docker ps | grep pytorch-rubi` != "" ]]; then
	echo "Stopping and removing existing container, press CTRL-C within 5 secs to cancel"
	for ((i=5; i>=1; i--)); do
    	    echo $i
	    sleep 1
	done
	
	$SUDO docker stop pytorch-rubi
	$SUDO docker container rm pytorch-rubi
    fi
}

#............................................................
#
# Runs a new Tensorflow container, gpu or cpu depending on
#   environment variable GPU
#
#............................................................
runTFContainer() {
    DOCKERARGS="-tid -p 8888:8888 --name tf-rubi -v $PWD:/home/RUBi"
    
    if [[ $GPU == "nvidia" ]]; then
        DOCKERARGS+=" --gpus all"
        $SUDO docker run $DOCKERARGS tf-gpu:latest
    else
        $SUDO docker run $DOCKERARGS tf-cpu:latest
    fi
}

#............................................................
#
# Runs a new PyTorch container, gpu or cpu depending on
#   environment variable GPU
#
#............................................................
runPyTorchContainer() {
    DOCKERARGS="-tid -p 8888:8888 --name pytorch-rubi -v $PWD:/home/RUBi"
    
    $SUDO docker run $DOCKERARGS pytorch-rubi:latest
}

parseArguments $@

deploy() {
    # Script has been curl'd, clone repo to current folder and deploy
    if [[ `basename $PWD` != "RUBi" ]]; then
        git clone https://github.com/$REPO/RUBi.git
        cd RUBi
        git checkout $BRANCH

        installPackages
        checkDockerPermissions
        buildPyTorchImage

        if [[ ! -z $DATASETS ]]; then
            getVisualFeatures
            getVQADataset
        fi

        checkDockerPermissions

        runPyTorchContainer
        splitVisualFeatures
    else
        checkDockerPermissions

        removePyTorchContainer
        runPyTorchContainer
    fi
    
    echo -e "\nThe Docker container is now online with the RUBi repo in /home/RUBi."
    echo 'Execute commands inside the container as <docker exec -it -w /home/RUBi -u $(id -u):$(id -g) pytorch-rubi bash -c "python3 ...">'
}

deploy

