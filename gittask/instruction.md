1. 先查看 https://github.com/microsoft/intelligent-terminal/pulls/DinahK-2SO 这里所有的 active PR，如果只有两个古老的PR： 
- https://github.com/microsoft/intelligent-terminal/pull/639

，说明没有新PR，直接退出此次任务。


如果发现了DinahK-2SO的新PR，对每一个新PR，拿到它的branch，然后：

1. 在repository文件夹 ./code/intelligent-terminal 中, find or create 这个PR的branch的work tree, then update its worktree to the latest interation of the branch of this new PR.

2. 在 reports 文件夹中，find or create 这个 PR的report folder: ./reports/<id of the new PR>

3. 查看这个PR里有没有能resolve的active comments：
https://github.com/microsoft/intelligent-terminal/pull/<id of the new PR>

对每一个active comment: 如果可以resolve，先按照以下格式回复: 
"Fixed in <commit id>, <explain how it was fixed in <50 words>."

然后resolve这个可以被resolve的comment。

4. 你可以在 ./code/intelligent-terminal folder 中查看历史git commits，可以pull 最新的 PR update到本地来方便你阅读，但是不要修改任何代码，不要commit，不要push

每次的行动的记录与intermediate files 写在当前./reports/<PR id> folder的子文件夹里，子文件夹的名字yyyy-mmdd-hhmm-<三位自增数组>，行动记录的名字为<子文件夹的名字>.md

每处理一个comment，就在 ./<子文件夹的名字>/<子文件夹的名字>.md 这个文件里 append一条记录，带有comment链接，决定（resolved/won't fix/active），回复内容（if any）



