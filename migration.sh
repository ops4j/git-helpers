#!/bin/bash

# From http://www.sonatype.com/people/2011/04/goodbye-svn-hello-git/

CURRENT_PATH=`pwd`

# file based URL for reads
SVN_URL=file:///path/to/repositories/sonatype.org/spice
SVN_REMOTE_URL=https://svn.sonatype.org/spice
SVN_TAGS_DIR=tags
SVN_TAG_PREFIX=$1
SVN_TRUNK_DIR=trunk/${SVN_TAG_PREFIX}
SVN_AUTHORS=/path/to/svn-authors.txt

GIT_REPO_NAME=$1
GITHUB_USER=userid
GITHUB_TOKEN=xxx
GITHUB_TEAM_ID=1234
GITHUB_ORG=sonatype

# this is the magic, get the list of tags that match this project the output format looks like:
# tags/{module-1.0,module-1.2,module-2.1}
GIT_TAG_ARG=${SVN_TAGS_DIR}/\{`svn list ${SVN_URL}/${SVN_TAGS_DIR} | grep ${SVN_TAG_PREFIX} | sed 's_/__' | xargs -I {} echo -n ,{} | sed 's_^,__'`\}

#echo ${GIT_TAG_ARG}

# init git repo
git svn init --trunk=${SVN_TRUNK_DIR} ${SVN_URL} ${SVN_TAG_PREFIX}

#copy authors text to repo
cp ${SVN_AUTHORS} ${SVN_TAG_PREFIX}/.svn-authors.txt

# move to directory
cd ${SVN_TAG_PREFIX}

# make sure we have tags for this project
if [ `svn list ${SVN_URL}/${SVN_TAGS_DIR} | grep ${SVN_TAG_PREFIX} | wc -l` -gt 0 ]; then
  #configure the tags, we only want a subset of the tags, because we lumpped all the tags in a single place.
  git config --add svn-remote.svn.tags ${GIT_TAG_ARG}:refs/remotes/tags/*
fi

#fetch
git svn fetch --authors-file=.svn-authors.txt
# make sure there are no errors before we continue
if [ "$?" -ne "0" ]; then
  echo "Error while fetching, see above"
  exit 1
fi

git update-ref -d master

##########################################################
# fix the tags, from: https://github.com/nothingmuch/git-svn-abandon
##########################################################

# create annotated tags out of svn tags
git for-each-ref --format='%(refname)' refs/remotes/tags/* | while read tag_ref; do
    tag=${tag_ref#refs/remotes/tags/}
    tree=$( git rev-parse "$tag_ref": )

    # find the oldest ancestor for which the tree is the same
    parent_ref="$tag_ref";
    while [ $( git rev-parse --quiet --verify "$parent_ref"^: ) = "$tree" ]; do
        parent_ref="$parent_ref"^
    done
    parent=$( git rev-parse "$parent_ref" );

    # if this ancestor is in trunk then we can just tag it
    # otherwise the tag has diverged from trunk and it's actually more like a
    # branch than a tag
    merge=$( git merge-base "refs/remotes/trunk" $parent );
    if [ "$merge" = "$parent" ]; then
        target_ref=$parent
    else
        echo "tag has diverged: $tag"
        target_ref="$tag_ref"
    fi

    # create an annotated tag based on the last commit in the tag, and delete the "branchy" ref for the tag
    git show -s --pretty='format:%s%n%n%b' "$tag_ref" | \
    perl -ne 'next if /^git-svn-id:/; $s++, next if /^\s*r\d+\@.*:.*\|/; s/^ // if $s; print' | \
    env GIT_COMMITTER_NAME="$(  git show -s --pretty='format:%an' "$tag_ref" )" \
        GIT_COMMITTER_EMAIL="$( git show -s --pretty='format:%ae' "$tag_ref" )" \
        GIT_COMMITTER_DATE="$(  git show -s --pretty='format:%ad' "$tag_ref" )" \
        git tag -a -F - "$tag" "$target_ref"

    git update-ref -d "$tag_ref"
done

# create local branches out of svn branches
git for-each-ref --format='%(refname)' refs/remotes/ | while read branch_ref; do
    branch=${branch_ref#refs/remotes/}
    git branch "$branch" "$branch_ref"
    git update-ref -d "$branch_ref"
done

# remove merged branches
git for-each-ref --format='%(refname)' refs/heads | while read branch; do
    git rev-parse --quiet --verify "$branch" || continue # make sure it still exists
    git symbolic-ref HEAD "$branch"
    git branch -d $( git branch --merged | grep -v '^\*' )
done
##########################################################
# done fixing tags
##########################################################

# we should already be on the master, but lets make sure
git checkout master

##
# Use the Github API to create a repo and add it to the team.
##

#create github repo
curl -F "login=${GITHUB_USER}" -F "token=${GITHUB_TOKEN}" https://github.com/api/v2/json/repos/create -F "name=${GITHUB_ORG}/${GIT_REPO_NAME}" -F "has_issues=false" -F "has_downloads=false" -F "has_wiki=false"  --request POST

#add the dev team to the repo
curl -F "login=${GITHUB_USER}" -F "token=${GITHUB_TOKEN}" -F "name=${GITHUB_ORG}/${GIT_REPO_NAME}" http://github.com/api/v2/json/teams/${GITHUB_TEAM_ID}/repositories

# set the origin
git remote add origin git@github.com:${GITHUB_ORG}/${GIT_REPO_NAME}.git
#push it all
git push --tags origin master

#go back to where we started
cd ${CURRENT_PATH}

# some reminders so we do not forget the manual steps
echo "--${GIT_REPO_NAME}--" >> migrate.out
echo "You should now review the git repo at: https://github.com/${GITHUB_ORG}/${GIT_REPO_NAME} then remove the svn repo with:" >> migrate.out
echo "$ svn rm ${SVN_REMOTE_URL}/${SVN_TRUNK_DIR} -m  \"Moved to github: https://github.com/${GITHUB_ORG}/${GIT_REPO_NAME}\"" >> migrate.out
echo "Do not forget to update the grid: https://grid.sonatype.org/ci/\" to use: git://github.com/${GITHUB_ORG}/${GIT_REPO_NAME}.git >> migrate.out
echo "Add redirect from ${SVN_REMOTE_URL}/${SVN_TRUNK_DIR} to https://github.com/${GITHUB_ORG}/${GIT_REPO_NAME}" >> migrate.out
echo "" >> migrate.out