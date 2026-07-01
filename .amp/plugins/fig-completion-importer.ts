import type { PluginAPI } from '@ampcode/plugin'
import { existsSync } from 'node:fs'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import path from 'node:path'

const FIG_REPO = 'withfig/autocomplete'
const FIG_REF = 'master'
const FIG_RAW_BASE = `https://raw.githubusercontent.com/${FIG_REPO}/${FIG_REF}/`

const FIG_SPEC_PATHS = [
	"src/act.ts",
	"src/adb.ts",
	"src/adr.ts",
	"src/afplay.ts",
	"src/aftman.ts",
	"src/ag.ts",
	"src/agrippa.ts",
	"src/airflow.ts",
	"src/amplify.ts",
	"src/ampx.ts",
	"src/ansible-config.ts",
	"src/ansible-doc.ts",
	"src/ansible-galaxy.ts",
	"src/ansible-lint.ts",
	"src/ansible-playbook.ts",
	"src/ansible.ts",
	"src/ant.ts",
	"src/appwrite.ts",
	"src/apt.ts",
	"src/arch.ts",
	"src/arduino-cli.ts",
	"src/argo.ts",
	"src/asar.ts",
	"src/asciinema.ts",
	"src/asdf.ts",
	"src/asr.ts",
	"src/assimp.ts",
	"src/astro.ts",
	"src/atlas.ts",
	"src/atuin.ts",
	"src/authchanger.ts",
	"src/autocannon.ts",
	"src/autojump.ts",
	"src/aws-vault.ts",
	"src/aws.ts",
	"src/awsume.ts",
	"src/az/index.ts",
	"src/babel.ts",
	"src/banner.ts",
	"src/barnard59.ts",
	"src/base32.ts",
	"src/base64.ts",
	"src/basename.ts",
	"src/basenc.ts",
	"src/bat.ts",
	"src/bazel.ts",
	"src/bc.ts",
	"src/bcd.ts",
	"src/bit.ts",
	"src/black.ts",
	"src/blitz.ts",
	"src/bosh.ts",
	"src/br.ts",
	"src/brew.ts",
	"src/broot.ts",
	"src/browser-sync.ts",
	"src/btop.ts",
	"src/build-storybook.ts",
	"src/bun.ts",
	"src/bundle.ts",
	"src/bunx.ts",
	"src/bw.ts",
	"src/bwdc.ts",
	"src/bws.ts",
	"src/c++.ts",
	"src/caffeinate.ts",
	"src/cal.ts",
	"src/cap.ts",
	"src/capacitor.ts",
	"src/cargo.ts",
	"src/cat.ts",
	"src/cci.ts",
	"src/cdk.ts",
	"src/cdk8s.ts",
	"src/cf.ts",
	"src/charm.ts",
	"src/checkov.ts",
	"src/chezmoi.ts",
	"src/chmod.ts",
	"src/chown.ts",
	"src/chsh.ts",
	"src/cicada.ts",
	"src/circleci.ts",
	"src/cl.ts",
	"src/clang++.ts",
	"src/clang.ts",
	"src/clear.ts",
	"src/cliff-jumper.ts",
	"src/clilol.ts",
	"src/clion.ts",
	"src/clojure.ts",
	"src/cloudflared.ts",
	"src/cmake.ts",
	"src/coda.ts",
	"src/code-insiders.ts",
	"src/code.ts",
	"src/codesign.ts",
	"src/command.ts",
	"src/commercelayer.ts",
	"src/composer.ts",
	"src/conda.ts",
	"src/copilot.ts",
	"src/copyfile.ts",
	"src/copypath.ts",
	"src/cordova.ts",
	"src/cosign.ts",
	"src/cot.ts",
	"src/cp.ts",
	"src/create-completion-spec.ts",
	"src/create-next-app.ts",
	"src/create-nx-workspace.ts",
	"src/create-react-app.ts",
	"src/create-react-native-app.ts",
	"src/create-redwood-app.ts",
	"src/create-remix.ts",
	"src/create-t3-app.ts",
	"src/create-video.ts",
	"src/create-vite.ts",
	"src/create-web3-frontend.ts",
	"src/croc.ts",
	"src/crontab.ts",
	"src/csdx.ts",
	"src/curl.ts",
	"src/cut.ts",
	"src/cw.ts",
	"src/dapr.ts",
	"src/dart.ts",
	"src/date.ts",
	"src/dateseq.ts",
	"src/datree.ts",
	"src/dbt.ts",
	"src/dcli.ts",
	"src/dd.ts",
	"src/ddev.ts",
	"src/ddosify.ts",
	"src/defaultbrowser.ts",
	"src/defaults.ts",
	"src/degit.ts",
	"src/deno.ts",
	"src/deployctl.ts",
	"src/deta.ts",
	"src/df.ts",
	"src/diff.ts",
	"src/dig.ts",
	"src/direnv.ts",
	"src/dirname.ts",
	"src/ditto.ts",
	"src/django-admin.ts",
	"src/do-release-upgrade.ts",
	"src/do.ts",
	"src/docker-compose.ts",
	"src/docker.ts",
	"src/doctl.ts",
	"src/dog.ts",
	"src/doggo.ts",
	"src/doppler.ts",
	"src/dos2unix.ts",
	"src/dotenv-vault.ts",
	"src/dotenv.ts",
	"src/dotnet.ts",
	"src/dotslash.ts",
	"src/dpkg.ts",
	"src/dprint.ts",
	"src/drush.ts",
	"src/dscacheutil.ts",
	"src/dscl.ts",
	"src/dtm.ts",
	"src/du.ts",
	"src/dust.ts",
	"src/eas.ts",
	"src/eb.ts",
	"src/echo.ts",
	"src/electron.ts",
	"src/eleventy.ts",
	"src/elif.ts",
	"src/elixir.ts",
	"src/elm-format.ts",
	"src/elm-json.ts",
	"src/elm-review.ts",
	"src/elm.ts",
	"src/else.ts",
	"src/emacs.ts",
	"src/enapter.ts",
	"src/encore.ts",
	"src/env.ts",
	"src/envchain.ts",
	"src/esbuild.ts",
	"src/eslint.ts",
	"src/exa.ts",
	"src/exec.ts",
	"src/exercism.ts",
	"src/expo-cli.ts",
	"src/expo.ts",
	"src/expressots.ts",
	"src/eza.ts",
	"src/fastlane.ts",
	"src/fastly.ts",
	"src/fd.ts",
	"src/fdisk.ts",
	"src/ffmpeg.ts",
	"src/fig/index.ts",
	"src/figterm.ts",
	"src/file.ts",
	"src/fin.ts",
	"src/find.ts",
	"src/firebase.ts",
	"src/firefox.ts",
	"src/fisher.ts",
	"src/flutter.ts",
	"src/fly.ts",
	"src/flyctl.ts",
	"src/fmt.ts",
	"src/fnm.ts",
	"src/fold.ts",
	"src/for.ts",
	"src/forc.ts",
	"src/forge.ts",
	"src/fvm.ts",
	"src/fzf-tmux.ts",
	"src/fzf.ts",
	"src/g++.ts",
	"src/ganache-cli.ts",
	"src/gatsby.ts",
	"src/gcc.ts",
	"src/gcloud.ts",
	"src/gem.ts",
	"src/gh.ts",
	"src/ghq.ts",
	"src/gibo.ts",
	"src/git-cliff.ts",
	"src/git-flow.ts",
	"src/git-profile.ts",
	"src/git-quick-stats.ts",
	"src/github.ts",
	"src/glow.ts",
	"src/gltfjsx.ts",
	"src/go.ts",
	"src/goctl.ts",
	"src/goland.ts",
	"src/googler.ts",
	"src/goreleaser.ts",
	"src/goto.ts",
	"src/gource.ts",
	"src/gpg.ts",
	"src/gradle.ts",
	"src/graphcdn.ts",
	"src/grep.ts",
	"src/grex.ts",
	"src/gron.ts",
	"src/gt.ts",
	"src/gum.ts",
	"src/hardhat.ts",
	"src/hasura.ts",
	"src/hb-service.ts",
	"src/head.ts",
	"src/helm.ts",
	"src/helmfile.ts",
	"src/herd.ts",
	"src/heroku/index.ts",
	"src/hexo.ts",
	"src/homey.ts",
	"src/hop.ts",
	"src/hostname.ts",
	"src/htop.ts",
	"src/http.ts",
	"src/https.ts",
	"src/httpy.ts",
	"src/hub.ts",
	"src/hugo.ts",
	"src/hx.ts",
	"src/hyper.ts",
	"src/hyperfine.ts",
	"src/ibus.ts",
	"src/iconv.ts",
	"src/id.ts",
	"src/idea.ts",
	"src/iex.ts",
	"src/if.ts",
	"src/ignite-cli.ts",
	"src/infracost/index.ts",
	"src/install.ts",
	"src/ionic.ts",
	"src/ipatool.ts",
	"src/j.ts",
	"src/java.ts",
	"src/jenv.ts",
	"src/jest.ts",
	"src/jmeter.ts",
	"src/join.ts",
	"src/jq.ts",
	"src/julia.ts",
	"src/jupyter.ts",
	"src/just.ts",
	"src/k3d.ts",
	"src/k6.ts",
	"src/k9s.ts",
	"src/kafkactl.ts",
	"src/kamal.ts",
	"src/kdoctor.ts",
	"src/keytool.ts",
	"src/kill.ts",
	"src/killall.ts",
	"src/kind.ts",
	"src/kitty.ts",
	"src/klist.ts",
	"src/knex.ts",
	"src/kool.ts",
	"src/kotlinc.ts",
	"src/kubecolor.ts",
	"src/kubectl.ts",
	"src/kubectx.ts",
	"src/kubens.ts",
	"src/laravel.ts",
	"src/launchctl.ts",
	"src/ldd.ts",
	"src/leaf.ts",
	"src/lerna.ts",
	"src/less.ts",
	"src/lima.ts",
	"src/limactl.ts",
	"src/ln.ts",
	"src/locust.ts",
	"src/login.ts",
	"src/lp.ts",
	"src/lpass.ts",
	"src/lsblk.ts",
	"src/lsd.ts",
	"src/lsof.ts",
	"src/luz.ts",
	"src/lvim.ts",
	"src/m.ts",
	"src/mackup.ts",
	"src/magento.ts",
	"src/maigret.ts",
	"src/mailsy.ts",
	"src/make.ts",
	"src/mamba.ts",
	"src/mas.ts",
	"src/mask.ts",
	"src/mdfind.ts",
	"src/mdls.ts",
	"src/meroxa.ts",
	"src/meteor.ts",
	"src/mgnl.ts",
	"src/micro.ts",
	"src/mikro-orm.ts",
	"src/minectl.ts",
	"src/minikube.ts",
	"src/mix.ts",
	"src/mkdocs.ts",
	"src/mkfifo.ts",
	"src/mkinitcpio.ts",
	"src/mknod.ts",
	"src/mob.ts",
	"src/molecule.ts",
	"src/mongocli.ts",
	"src/mongoimport.ts",
	"src/mongosh.ts",
	"src/more.ts",
	"src/mosh.ts",
	"src/mount.ts",
	"src/multipass.ts",
	"src/mv.ts",
	"src/mvn.ts",
	"src/mypy.ts",
	"src/mysql.ts",
	"src/n.ts",
	"src/nano.ts",
	"src/nativescript.ts",
	"src/nc.ts",
	"src/ncal.ts",
	"src/ncu.ts",
	"src/neofetch.ts",
	"src/nest.ts",
	"src/netlify.ts",
	"src/networkQuality.ts",
	"src/networksetup.ts",
	"src/newman.ts",
	"src/next.ts",
	"src/nextflow.ts",
	"src/ng.ts",
	"src/nginx.ts",
	"src/ngrok.ts",
	"src/nhost.ts",
	"src/ni.ts",
	"src/nl.ts",
	"src/nmap.ts",
	"src/nocorrect.ts",
	"src/node.ts",
	"src/noglob.ts",
	"src/northflank.ts",
	"src/np.ts",
	"src/npm.ts",
	"src/npx.ts",
	"src/nr.ts",
	"src/nrm.ts",
	"src/ns.ts",
	"src/nu.ts",
	"src/nuxi.ts",
	"src/nuxt.ts",
	"src/nvim.ts",
	"src/nvm.ts",
	"src/nx.ts",
	"src/nylas.ts",
	"src/oci.ts",
	"src/od.ts",
	"src/oh-my-posh.ts",
	"src/okta.ts",
	"src/okteto.ts",
	"src/ollama.ts",
	"src/omz.ts",
	"src/onboardbase.ts",
	"src/op.ts",
	"src/opa.ts",
	"src/open.ts",
	"src/osascript.ts",
	"src/osqueryi.ts",
	"src/oxlint.ts",
	"src/pac.ts",
	"src/pageres.ts",
	"src/palera1n.ts",
	"src/pandoc.ts",
	"src/paper.ts",
	"src/pass.ts",
	"src/passwd.ts",
	"src/paste.ts",
	"src/pathchk.ts",
	"src/pdfunite.ts",
	"src/pg_dump.ts",
	"src/pgcli.ts",
	"src/php.ts",
	"src/phpstorm.ts",
	"src/phpunit-watcher.ts",
	"src/phpunit.ts",
	"src/pijul.ts",
	"src/ping.ts",
	"src/pip.ts",
	"src/pip3.ts",
	"src/pipenv.ts",
	"src/pipx.ts",
	"src/pkg-config.ts",
	"src/pkgutil.ts",
	"src/pkill.ts",
	"src/planter.ts",
	"src/playwright.ts",
	"src/plutil.ts",
	"src/pm2.ts",
	"src/pmset.ts",
	"src/pnpx.ts",
	"src/pocketbase.ts",
	"src/pod.ts",
	"src/podman.ts",
	"src/poetry.ts",
	"src/pre-commit.ts",
	"src/premake.ts",
	"src/preset.ts",
	"src/prettier.ts",
	"src/prisma.ts",
	"src/pro.ts",
	"src/progressline.ts",
	"src/projj.ts",
	"src/pry.ts",
	"src/ps.ts",
	"src/pscale.ts",
	"src/psql.ts",
	"src/publish.ts",
	"src/pulumi.ts",
	"src/pushd.ts",
	"src/pycharm.ts",
	"src/pyenv.ts",
	"src/pytest.ts",
	"src/python.ts",
	"src/python3.ts",
	"src/q.ts",
	"src/qodana.ts",
	"src/quasar.ts",
	"src/quickmail.ts",
	"src/r.ts",
	"src/rails.ts",
	"src/railway.ts",
	"src/rake.ts",
	"src/rancher.ts",
	"src/rbenv.ts",
	"src/rclone.ts",
	"src/react-native.ts",
	"src/readlink.ts",
	"src/redwood.ts",
	"src/remix.ts",
	"src/remotion.ts",
	"src/repeat.ts",
	"src/rg.ts",
	"src/rich.ts",
	"src/rm.ts",
	"src/robot.ts",
	"src/rojo.ts",
	"src/rollup.ts",
	"src/rome.ts",
	"src/rscript.ts",
	"src/rsync.ts",
	"src/rubocop.ts",
	"src/ruby.ts",
	"src/rubymine.ts",
	"src/ruff.ts",
	"src/rugby.ts",
	"src/rush.ts",
	"src/rushx.ts",
	"src/rustc.ts",
	"src/rustrover.ts",
	"src/rustup.ts",
	"src/rvm.ts",
	"src/sake.ts",
	"src/sam.ts",
	"src/sanity.ts",
	"src/sapphire.ts",
	"src/scarb.ts",
	"src/scc.ts",
	"src/scp.ts",
	"src/screen.ts",
	"src/sed.ts",
	"src/seq.ts",
	"src/sequelize.ts",
	"src/serve.ts",
	"src/serverless.ts",
	"src/sfdx.ts",
	"src/sftp.ts",
	"src/sha1sum.ts",
	"src/shadcn-ui.ts",
	"src/shasum.ts",
	"src/shell-config.ts",
	"src/shelve.ts",
	"src/shopify/index.ts",
	"src/shortcuts.ts",
	"src/shred.ts",
	"src/sidekiq.ts",
	"src/simctl.ts",
	"src/sips.ts",
	"src/sl.ts",
	"src/sls.ts",
	"src/snaplet.ts",
	"src/softwareupdate.ts",
	"src/sort.ts",
	"src/space.ts",
	"src/speedtest-cli.ts",
	"src/speedtest.ts",
	"src/splash.ts",
	"src/split.ts",
	"src/spotify.ts",
	"src/spring.ts",
	"src/sqlfluff.ts",
	"src/sqlite3.ts",
	"src/sqlmesh.ts",
	"src/src.ts",
	"src/ssh-keygen.ts",
	"src/ssh.ts",
	"src/st2.ts",
	"src/sta.ts",
	"src/stack.ts",
	"src/starkli.ts",
	"src/start-storybook.ts",
	"src/stat.ts",
	"src/steadybit.ts",
	"src/stencil.ts",
	"src/stepzen.ts",
	"src/stow.ts",
	"src/streamlit.ts",
	"src/stripe.ts",
	"src/su.ts",
	"src/subl.ts",
	"src/sudo.ts",
	"src/suitecloud.ts",
	"src/supabase.ts",
	"src/surreal.ts",
	"src/svn.ts",
	"src/svokit.ts",
	"src/svtplay-dl.ts",
	"src/sw_vers.ts",
	"src/swagger-typescript-api.ts",
	"src/swc.ts",
	"src/swift.ts",
	"src/symfony.ts",
	"src/sysctl.ts",
	"src/systemctl.ts",
	"src/tac.ts",
	"src/tail.ts",
	"src/tailcall.ts",
	"src/tailscale.ts",
	"src/tailwindcss.ts",
	"src/tangram.ts",
	"src/taplo.ts",
	"src/tar.ts",
	"src/task.ts",
	"src/tb.ts",
	"src/tccutil.ts",
	"src/tee.ts",
	"src/terraform.ts",
	"src/terragrunt.ts",
	"src/tfenv.ts",
	"src/tfsec.ts",
	"src/then.ts",
	"src/time.ts",
	"src/tkn.ts",
	"src/tldr.ts",
	"src/tmutil.ts",
	"src/tmux.ts",
	"src/tmuxinator.ts",
	"src/tns.ts",
	"src/tokei.ts",
	"src/top.ts",
	"src/touch.ts",
	"src/tr.ts",
	"src/traceroute.ts",
	"src/trap.ts",
	"src/trash.ts",
	"src/tree.ts",
	"src/trex.ts",
	"src/trivy.ts",
	"src/truffle.ts",
	"src/truncate.ts",
	"src/trunk.ts",
	"src/ts-node.ts",
	"src/tsc.ts",
	"src/tsh.ts",
	"src/tsuru.ts",
	"src/tsx.ts",
	"src/tuist.ts",
	"src/turbo.ts",
	"src/twiggy.ts",
	"src/twilio.ts",
	"src/typeorm.ts",
	"src/typos.ts",
	"src/typst.ts",
	"src/ua.ts",
	"src/ubuntu-advantage.ts",
	"src/uname.ts",
	"src/uniq.ts",
	"src/unix2dos.ts",
	"src/until.ts",
	"src/unzip.ts",
	"src/uv.ts",
	"src/v.ts",
	"src/vale.ts",
	"src/valet.ts",
	"src/vapor.ts",
	"src/vault.ts",
	"src/vela.ts",
	"src/vercel.ts",
	"src/vi.ts",
	"src/vim.ts",
	"src/vimr.ts",
	"src/visudo.ts",
	"src/vite.ts",
	"src/volta.ts",
	"src/vr.ts",
	"src/vsce.ts",
	"src/vtex.ts",
	"src/vue.ts",
	"src/vultr-cli.ts",
	"src/w.ts",
	"src/wasm-bindgen.ts",
	"src/wasm-pack.ts",
	"src/watchman.ts",
	"src/watson.ts",
	"src/wc.ts",
	"src/wd.ts",
	"src/webpack.ts",
	"src/webstorm.ts",
	"src/wezterm.ts",
	"src/wget.ts",
	"src/whence.ts",
	"src/where.ts",
	"src/whereis.ts",
	"src/which.ts",
	"src/while.ts",
	"src/who.ts",
	"src/whois.ts",
	"src/wifi-password.ts",
	"src/wing.ts",
	"src/wp.ts",
	"src/wrangler.ts",
	"src/wrk.ts",
	"src/wscat.ts",
	"src/xargs.ts",
	"src/xc.ts",
	"src/xcode-select.ts",
	"src/xcodebuild.ts",
	"src/xcodeproj.ts",
	"src/xcodes.ts",
	"src/xcrun.ts",
	"src/xdg-mime.ts",
	"src/xdg-open.ts",
	"src/xed.ts",
	"src/xxd.ts",
	"src/yalc.ts",
	"src/yank.ts",
	"src/yarn.ts",
	"src/ykman.ts",
	"src/yo.ts",
	"src/yomo.ts",
	"src/youtube-dl.ts",
	"src/z.ts",
	"src/zapier.ts",
	"src/zed.ts",
	"src/zellij.ts",
	"src/zip.ts",
	"src/zipcloak.ts",
	"src/zoxide.ts",
] as const

type ImportStatus = 'todo' | 'in_progress' | 'done' | 'skipped'

type ImportRecord = {
	status: ImportStatus
	commandHint: string
	claimedBy?: string
	claimedAt?: string
	completedAt?: string
	notes?: string
	attempts?: number
}

type ImportState = {
	version: 1
	cursor: number
	records: Record<string, ImportRecord>
	currentByThread: Record<string, string>
}

type ParseNote = {
	path: string
	reason: string
	snippet?: string
}

type ParseResult = {
	value: unknown
	notes: ParseNote[]
}

type ConvertResult = {
	commandName: string
	manifest: Record<string, unknown>
	reviewNotesMarkdown: string
	dynamicProviderStubs: string
	stats: Record<string, number>
}

const workspaceRoot = process.cwd()
const stateFile = path.join(workspaceRoot, '.amp', 'fig-completion-import-state.json')
const outputRoot = path.join(workspaceRoot, '.amp', 'fig-completion-import')

export default function (amp: PluginAPI) {
	amp.logger.log(`Fig completion importer loaded with ${FIG_SPEC_PATHS.length} Fig specs`)

	amp.registerTool({
		name: 'fig_completion_status',
		description: 'Show progress for the Fig-to-Rush completion import queue.',
		inputSchema: {
			type: 'object',
			properties: {
				limit: { type: 'number', description: 'Maximum number of current/in-progress entries to show' },
			},
		},
		async execute(input, ctx) {
			const state = await loadState()
			const limit = typeof input.limit === 'number' ? Math.max(1, Math.min(100, Math.trunc(input.limit))) : 20
			return JSON.stringify(summarizeState(state, ctx.thread.id, limit), null, 2)
		},
	})

	amp.registerTool({
		name: 'fig_completion_next_command',
		description:
			'Claim the next Fig completion spec for this thread. Returns source URL, expected output paths, and worker instructions.',
		inputSchema: {
			type: 'object',
			properties: {
				command: { type: 'string', description: 'Optional Fig command hint, Rush command name, or src/... spec path to claim' },
				force: { type: 'boolean', description: 'Claim even if the spec is already in progress' },
			},
		},
		async execute(input, ctx) {
			const state = await loadState()
			const selected = selectSpec(state, typeof input.command === 'string' ? input.command : undefined, input.force === true)
			if (!selected) return JSON.stringify({ ok: false, message: 'No todo Fig completion specs remain.' }, null, 2)

			const now = new Date().toISOString()
			const record = state.records[selected.specPath]
			record.status = 'in_progress'
			record.claimedBy = ctx.thread.id
			record.claimedAt = now
			record.attempts = (record.attempts ?? 0) + 1
			state.currentByThread[ctx.thread.id] = selected.specPath
			state.cursor = (selected.index + 1) % FIG_SPEC_PATHS.length
			await saveState(state)

			const commandHint = commandHintForSpecPath(selected.specPath)
			return JSON.stringify(
				{
					ok: true,
					specPath: selected.specPath,
					commandHint,
					sourceUrl: rawUrl(selected.specPath),
					expectedManifestPath: `share/rush/completions/${safeFileName(commandHint)}.json`,
					expectedProviderPath: `share/rush/completions/${safeFileName(commandHint)}.rush`,
					instructions: [
						'Call fig_completion_convert for this spec to write the static JSON draft and return review notes.',
						'Inspect the tool-returned review notes for skipped generators, generateSpec, loadSpec, spreads, helper calls, and insertValue behavior.',
						'Hand-port dynamic behavior into a .rush provider script using read-only commands only.',
						'Validate JSON and any focused completion checks that make sense.',
						'Commit and push only if the user/workflow has asked you to do so and credentials/branch policy allow it.',
						'Call fig_completion_command_complete when the command is fully converted or intentionally skipped.',
					],
				},
				null,
				2,
			)
		},
	})

	amp.registerTool({
		name: 'fig_completion_convert',
		description:
			'Fetch a Fig completion spec and convert the statically understood parts into a Rush JSON manifest draft plus review notes.',
		inputSchema: {
			type: 'object',
			properties: {
				specPath: { type: 'string', description: 'Optional src/... Fig spec path. Defaults to this thread’s claimed spec.' },
				command: { type: 'string', description: 'Optional command hint or src/... path to convert' },
				write: { type: 'boolean', description: 'Write draft files. Defaults to true.' },
				overwrite: { type: 'boolean', description: 'Overwrite an existing share/rush/completions/<cmd>.json file.' },
			},
		},
		async execute(input, ctx) {
			const state = await loadState()
			const specPath = resolveRequestedSpecPath(
				state,
				ctx.thread.id,
				typeof input.specPath === 'string' ? input.specPath : typeof input.command === 'string' ? input.command : undefined,
			)
			if (!specPath) {
				return JSON.stringify({ ok: false, message: 'No spec path requested and this thread has no claimed spec.' }, null, 2)
			}

			const source = await fetchText(rawUrl(specPath))
			const converted = convertFigSourceToRush(source, specPath)
			const writeFiles = input.write !== false
			const overwrite = input.overwrite === true
			const written: Record<string, string> = {}
			const manifestJson = JSON.stringify(converted.manifest, null, 2) + '\n'

			if (writeFiles) {
				await mkdir(outputRoot, { recursive: true })
				await mkdir(path.join(outputRoot, 'drafts'), { recursive: true })
				await mkdir(path.join(outputRoot, 'providers'), { recursive: true })
				await mkdir(path.join(workspaceRoot, 'share', 'rush', 'completions'), { recursive: true })

				const fileBase = safeFileName(converted.commandName)
				const manifestPath = path.join(workspaceRoot, 'share', 'rush', 'completions', `${fileBase}.json`)
				const draftPath = path.join(outputRoot, 'drafts', `${fileBase}.json`)
				const providerStubPath = path.join(outputRoot, 'providers', `${fileBase}.rush`)

				if (!existsSync(manifestPath) || overwrite) {
					await writeFile(manifestPath, manifestJson, 'utf8')
					written.manifest = path.relative(workspaceRoot, manifestPath)
				} else {
					await writeFile(draftPath, manifestJson, 'utf8')
					written.draftManifest = path.relative(workspaceRoot, draftPath)
				}
				if (converted.dynamicProviderStubs.trim().length > 0) {
					await writeFile(providerStubPath, converted.dynamicProviderStubs, 'utf8')
					written.providerStubs = path.relative(workspaceRoot, providerStubPath)
				}
			}

			return JSON.stringify(
				{
					ok: true,
					specPath,
					commandName: converted.commandName,
					stats: converted.stats,
					written,
					manifest: writeFiles ? undefined : converted.manifest,
					reviewNotes: converted.reviewNotesMarkdown,
				},
				null,
				2,
			)
		},
	})

	amp.registerTool({
		name: 'fig_completion_command_complete',
		description: 'Mark this thread’s current Fig completion command done or skipped in the importer state.',
		inputSchema: {
			type: 'object',
			properties: {
				specPath: { type: 'string', description: 'Optional src/... Fig spec path. Defaults to this thread’s claimed spec.' },
				status: { type: 'string', enum: ['done', 'skipped'], description: 'Completion status to record. Defaults to done.' },
				notes: { type: 'string', description: 'Short completion/skip notes.' },
			},
		},
		async execute(input, ctx) {
			const state = await loadState()
			const specPath = resolveRequestedSpecPath(state, ctx.thread.id, typeof input.specPath === 'string' ? input.specPath : undefined)
			if (!specPath) return JSON.stringify({ ok: false, message: 'No spec path supplied or claimed by this thread.' }, null, 2)
			const record = state.records[specPath]
			if (!record) return JSON.stringify({ ok: false, message: `Unknown Fig spec path: ${specPath}` }, null, 2)
			record.status = input.status === 'skipped' ? 'skipped' : 'done'
			record.completedAt = new Date().toISOString()
			if (typeof input.notes === 'string') record.notes = input.notes
			delete state.currentByThread[ctx.thread.id]
			await saveState(state)
			const summary = summarizeState(state, ctx.thread.id, 10).counts
			const nextMessageSent = summary.todo > 0
			if (nextMessageSent) {
				await ctx.thread.appendUserMessage({ type: 'user-message', content: 'pick the next command' })
			}
			return JSON.stringify({ ok: true, specPath, record, summary, nextMessageSent }, null, 2)
		},
	})

}

async function loadState(): Promise<ImportState> {
	await mkdir(path.dirname(stateFile), { recursive: true })
	let state: ImportState | undefined
	try {
		state = JSON.parse(await readFile(stateFile, 'utf8')) as ImportState
	} catch {
		state = { version: 1, cursor: 0, records: {}, currentByThread: {} }
	}
	if (state.version !== 1) state = { version: 1, cursor: 0, records: {}, currentByThread: {} }
	for (const specPath of FIG_SPEC_PATHS) {
		if (!state.records[specPath]) {
			state.records[specPath] = { status: 'todo', commandHint: commandHintForSpecPath(specPath) }
		}
	}
	let removedRecords = false
	for (const specPath of Object.keys(state.records)) {
		if (!(FIG_SPEC_PATHS as readonly string[]).includes(specPath)) {
			delete state.records[specPath]
			removedRecords = true
		}
	}
	state.cursor = removedRecords ? 0 : Math.max(0, Math.min(FIG_SPEC_PATHS.length - 1, state.cursor || 0))
	state.currentByThread ??= {}
	return state
}

async function saveState(state: ImportState): Promise<void> {
	await mkdir(path.dirname(stateFile), { recursive: true })
	const tmp = `${stateFile}.${process.pid}.${Date.now()}.tmp`
	await writeFile(tmp, JSON.stringify(state, null, 2) + '\n', 'utf8')
	await rename(tmp, stateFile)
}

function summarizeState(state: ImportState, threadID: string, limit: number) {
	const counts: Record<ImportStatus, number> = { todo: 0, in_progress: 0, done: 0, skipped: 0 }
	for (const record of Object.values(state.records)) counts[record.status] += 1
	const currentSpecPath = state.currentByThread[threadID]
	const inProgress = Object.entries(state.records)
		.filter(([, record]) => record.status === 'in_progress')
		.slice(0, limit)
		.map(([specPath, record]) => ({ specPath, ...record }))
	const next = peekNextTodo(state)
	return { total: FIG_SPEC_PATHS.length, counts, cursor: state.cursor, currentSpecPath, next, inProgress }
}

function selectSpec(state: ImportState, request: string | undefined, force: boolean): { specPath: string; index: number } | undefined {
	if (request) {
		const specPath = findSpecPath(request)
		if (!specPath) return undefined
		const record = state.records[specPath]
		if (!force && record.status !== 'todo') return undefined
		return { specPath, index: FIG_SPEC_PATHS.indexOf(specPath as (typeof FIG_SPEC_PATHS)[number]) }
	}
	for (let offset = 0; offset < FIG_SPEC_PATHS.length; offset += 1) {
		const index = (state.cursor + offset) % FIG_SPEC_PATHS.length
		const specPath = FIG_SPEC_PATHS[index]
		if (state.records[specPath].status === 'todo') return { specPath, index }
	}
	return undefined
}

function peekNextTodo(state: ImportState) {
	const selected = selectSpec(state, undefined, false)
	return selected ? { specPath: selected.specPath, commandHint: commandHintForSpecPath(selected.specPath) } : null
}

function resolveRequestedSpecPath(state: ImportState, threadID: string, request?: string): string | undefined {
	if (request) return findSpecPath(request)
	return state.currentByThread[threadID]
}

function findSpecPath(request: string): string | undefined {
	const normalized = request.trim()
	if ((FIG_SPEC_PATHS as readonly string[]).includes(normalized)) return normalized
	const withoutExt = normalized.replace(/\.ts$/, '')
	const candidates = FIG_SPEC_PATHS.filter((specPath) => {
		const hint = commandHintForSpecPath(specPath)
		return hint === normalized || hint === withoutExt || specPath === `src/${withoutExt}.ts` || specPath.endsWith(`/${withoutExt}.ts`)
	})
	return candidates[0]
}

function commandHintForSpecPath(specPath: string): string {
	const relative = specPath.replace(/^src\//, '').replace(/\.ts$/, '')
	if (relative.endsWith('/index')) return relative.slice(0, -'/index'.length).split('/').pop() || relative
	return relative.split('/').pop() || relative
}

function rawUrl(specPath: string): string {
	return FIG_RAW_BASE + specPath
}

async function fetchText(url: string): Promise<string> {
	const response = await fetch(url)
	if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status} ${response.statusText}`)
	return await response.text()
}

function convertFigSourceToRush(source: string, specPath: string): ConvertResult {
	const parse = parseFigSpec(source)
	const notes = [...parse.notes]
	if (!parse.value || typeof parse.value !== 'object') {
		throw new Error(`Could not parse a static Fig completion object from ${specPath}`)
	}
	const stats = { commands: 0, options: 0, arguments: 0, staticValues: 0, dynamicNotes: notes.length }
	const providers = new Set<string>()
	const command = convertCommand(parse.value as Record<string, unknown>, '', notes, stats, providers)
	if (!command.name) command.name = commandHintForSpecPath(specPath)
	const commandName = Array.isArray(command.name) ? String(command.name[0]) : String(command.name)
	if (providers.size > 0) {
		const providerObject: Record<string, unknown> = {}
		for (const provider of [...providers].sort()) {
			if (provider === 'builtin.files') providerObject[provider] = { builtin: 'files' }
			if (provider === 'builtin.directories') providerObject[provider] = { builtin: 'directories' }
			if (provider === 'builtin.executables') providerObject[provider] = { builtin: 'executables' }
		}
		command.providers = { ...(providerObject as object), ...((command.providers as object | undefined) ?? {}) }
	}
	const manifest = {
		$schema: 'https://rush.horse/completion/schema/v1.schema.json',
		manifestVersion: 1,
		command,
	}
	const dynamicNotes = notes.filter((note) => note.reason !== 'ignored ui metadata')
	return {
		commandName,
		manifest,
		reviewNotesMarkdown: buildReviewNotes(specPath, commandName, stats, dynamicNotes),
		dynamicProviderStubs: buildProviderStubs(commandName, dynamicNotes),
		stats,
	}
}

function convertCommand(
	fig: Record<string, unknown>,
	pathPrefix: string,
	notes: ParseNote[],
	stats: Record<string, number>,
	providers: Set<string>,
): Record<string, unknown> {
	stats.commands += 1
	const command: Record<string, unknown> = {}
	const names = stringArray(fig.name)
	if (names.length === 1) command.name = names[0]
	if (names.length > 1) {
		command.name = names[0]
		command.aliases = names.slice(1).filter(isRushName)
	}
	if (typeof fig.description === 'string') command.description = cleanDescription(fig.description)
	if (fig.isHidden === true || fig.hidden === true) command.hidden = true
	if (fig.isDeprecated === true || fig.deprecated === true) command.deprecated = true
	if (typeof fig.deprecated === 'string') command.deprecated = fig.deprecated

	const options = arrayOfObjects(fig.options)
	if (options.length > 0) command.options = options.flatMap((option, index) => {
		const converted = convertOption(option, `${pathPrefix}.options[${index}]`, notes, stats, providers)
		return converted ? [converted] : []
	})

	const argumentModel = convertArguments(fig.args, `${pathPrefix}.args`, notes, stats, providers)
	if (argumentModel) command.arguments = argumentModel

	const subcommands = arrayOfObjects(fig.subcommands)
	if (subcommands.length > 0) command.subcommands = subcommands.flatMap((subcommand, index) => {
		if (typeof subcommand.loadSpec === 'string') {
			notes.push({ path: `${pathPrefix}.subcommands[${index}].loadSpec`, reason: `loadSpec requires hand conversion: ${subcommand.loadSpec}` })
		}
		const converted = convertCommand(subcommand, `${pathPrefix}.subcommands[${index}]`, notes, stats, providers)
		return converted.name ? [converted] : []
	})

	for (const field of ['generateSpec', 'loadSpec']) {
		if (field in fig) notes.push({ path: `${pathPrefix}.${field}`, reason: `${field} requires hand conversion` })
	}
	for (const field of ['icon', 'displayName']) {
		if (field in fig) notes.push({ path: `${pathPrefix}.${field}`, reason: 'ignored ui metadata' })
	}
	return command
}

function convertOption(
	fig: Record<string, unknown>,
	where: string,
	notes: ParseNote[],
	stats: Record<string, number>,
	providers: Set<string>,
): Record<string, unknown> | undefined {
	const names = stringArray(fig.name)
	if (names.length === 0) {
		notes.push({ path: where, reason: 'option without a static name was skipped' })
		return undefined
	}
	const option: Record<string, unknown> = {}
	const spellings: string[] = []
	const longAliases: string[] = []
	for (const spelling of names) {
		if (/^--[A-Za-z0-9][A-Za-z0-9_-]*$/.test(spelling)) {
			const long = spelling.slice(2)
			if (!option.long) option.long = long
			else longAliases.push(long)
		} else if (/^-[^-\s]$/.test(spelling)) {
			const short = spelling.slice(1)
			if (!option.short) option.short = short
			else spellings.push(spelling)
		} else if (spelling.length > 0) {
			spellings.push(spelling)
		}
	}
	if (longAliases.length > 0) option.aliases = longAliases
	if (spellings.length > 0) option.spellings = [...new Set(spellings)]
	if (!option.long && !option.short && !option.spellings) return undefined
	if (typeof fig.description === 'string') option.description = cleanDescription(fig.description)
	if (fig.isDangerous === true) option.priority = -10
	if (fig.isRepeatable === true || fig.isRepeatable === 1) option.repeatable = true
	// Fig options only flow into subcommands when isPersistent is set. Rush's
	// engine default is inheritance, so generated drafts must opt out unless Fig
	// explicitly opted in.
	option.inherit = fig.isPersistent === true
	if (fig.isHidden === true || fig.hidden === true) option.hidden = true
	if (fig.isDeprecated === true || fig.deprecated === true) option.deprecated = true
	if (typeof fig.deprecated === 'string') option.deprecated = fig.deprecated
	const value = convertOptionValue(fig.args, `${where}.args`, notes, stats, providers)
	if (value) option.value = value
	for (const field of ['insertValue', 'dependsOn', 'exclusiveOn', 'requiresSeparator']) {
		if (field in fig) notes.push({ path: `${where}.${field}`, reason: `${field} needs review or hand mapping` })
	}
	stats.options += 1
	return option
}

function convertOptionValue(
	args: unknown,
	where: string,
	notes: ParseNote[],
	stats: Record<string, number>,
	providers: Set<string>,
): unknown {
	if (!args) return undefined
	const argObjects = Array.isArray(args) ? args.filter(isObject) : isObject(args) ? [args] : []
	if (argObjects.length === 0) return undefined
	const values = argObjects.map((arg, index) => convertValue(arg, `${where}${Array.isArray(args) ? `[${index}]` : ''}`, notes, stats, providers))
	return values.length === 1 ? values[0] : values
}

function convertArguments(
	args: unknown,
	where: string,
	notes: ParseNote[],
	stats: Record<string, number>,	
	providers: Set<string>,
): unknown {
	if (!args) return undefined
	const argObjects = Array.isArray(args) ? args.filter(isObject) : isObject(args) ? [args] : []
	if (argObjects.length === 0) return undefined
	const states = argObjects.map((arg, index) => {
		const value = convertValue(arg, `${where}${Array.isArray(args) ? `[${index}]` : ''}`, notes, stats, providers) as Record<string, unknown>
		const state: Record<string, unknown> = { ...value, index }
		delete state.required
		delete state.style
		if (arg.isVariadic === true) state.repeatable = true
		stats.arguments += 1
		return state
	})
	return { states }
}

function convertValue(
	arg: Record<string, unknown>,
	where: string,
	notes: ParseNote[],
	stats: Record<string, number>,
	providers: Set<string>,
): Record<string, unknown> {
	const value: Record<string, unknown> = {}
	value.name = typeof arg.name === 'string' ? safeValueName(arg.name) : 'value'
	if (typeof arg.description === 'string') value.description = cleanDescription(arg.description)
	if (arg.isOptional === true) {
		value.required = false
		value.style = 'optional'
	}
	const provider = providerForArg(arg, where, notes, stats, providers)
	if (provider) value.provider = provider
	for (const field of ['generators', 'generator', 'isModule', 'isScript']) {
		if (field in arg) notes.push({ path: `${where}.${field}`, reason: `${field} may require a hand-written Rush provider` })
	}
	return value
}

function providerForArg(
	arg: Record<string, unknown>,
	where: string,
	notes: ParseNote[],
	stats: Record<string, number>,
	providers: Set<string>,
): unknown {
	const suggestionProvider = suggestionsProvider(arg.suggestions, stats, notes, `${where}.suggestions`)
	if (suggestionProvider) return suggestionProvider
	const templateProvider = templateToProvider(arg.template, providers)
	if (templateProvider) return templateProvider
	if (arg.isCommand === true) {
		providers.add('builtin.executables')
		return 'builtin.executables'
	}
	if (arg.isScript === true) {
		providers.add('builtin.files')
		return 'builtin.files'
	}
	return undefined
}

function suggestionsProvider(suggestions: unknown, stats: Record<string, number>, notes: ParseNote[], where: string): unknown {
	if (!Array.isArray(suggestions)) return undefined
	const values = []
	for (let i = 0; i < suggestions.length; i += 1) {
		const suggestion = suggestions[i]
		if (typeof suggestion === 'string') values.push(suggestion)
		else if (isObject(suggestion)) {
			const names = stringArray(suggestion.name)
			for (const name of names) {
				const item: Record<string, unknown> = { value: name }
				if (typeof suggestion.description === 'string') item.description = cleanDescription(suggestion.description)
				if (typeof suggestion.priority === 'number') item.priority = clampPriority(suggestion.priority)
				if (typeof suggestion.insertValue === 'string' && suggestion.insertValue !== name) {
					notes.push({ path: `${where}[${i}].insertValue`, reason: 'suggestion insertValue needs hand review' })
				}
				values.push(item)
			}
		}
	}
	if (values.length === 0) return undefined
	stats.staticValues += values.length
	return { values }
}

function templateToProvider(template: unknown, providers: Set<string>): unknown {
	const templates = Array.isArray(template) ? template.filter((item): item is string => typeof item === 'string') : typeof template === 'string' ? [template] : []
	const refs = templates.flatMap((item) => {
		if (['filepaths', 'files', 'file'].includes(item)) return ['builtin.files']
		if (['folders', 'directories', 'directory'].includes(item)) return ['builtin.directories']
		if (['executables', 'commands'].includes(item)) return ['builtin.executables']
		return []
	})
	for (const ref of refs) providers.add(ref)
	const unique = [...new Set(refs)]
	if (unique.length === 0) return undefined
	return unique.length === 1 ? unique[0] : unique
}

function buildReviewNotes(specPath: string, commandName: string, stats: Record<string, number>, notes: ParseNote[]): string {
	const sourceUrl = rawUrl(specPath)
	const lines = [
		`# Fig completion conversion: ${commandName}`,
		'',
		`- Fig source: ${sourceUrl}`,
		`- Fig spec path: \`${specPath}\``,
		`- Rush manifest: \`share/rush/completions/${safeFileName(commandName)}.json\``,
		`- Suggested provider script: \`share/rush/completions/${safeFileName(commandName)}.rush\``,
		'',
		'## Static conversion stats',
		'',
		`- commands: ${stats.commands}`,
		`- options: ${stats.options}`,
		`- arguments: ${stats.arguments}`,
		`- static values: ${stats.staticValues}`,
		'',
		'## Needs hand conversion or review',
		'',
	]
	const relevant = notes.filter((note) => note.reason !== 'ignored ui metadata')
	if (relevant.length === 0) lines.push('- none found by the static converter')
	else {
		for (const note of relevant) {
			lines.push(`- \`${note.path || '<root>'}\`: ${note.reason}${note.snippet ? ` — \`${oneLine(note.snippet)}\`` : ''}`)
		}
	}
	lines.push('', '## Worker checklist', '', '- compare questionable mappings against the Fig source', '- hand-port safe dynamic generators into `.rush` providers', '- keep provider functions read-only and side-effect free', '- validate JSON before marking done', '')
	return lines.join('\n')
}

function buildProviderStubs(commandName: string, notes: ParseNote[]): string {
	const dynamic = notes.filter((note) => /generator|generateSpec|loadSpec|spread|unsupported|helper|hand/.test(note.reason))
	if (dynamic.length === 0) return ''
	const safe = safeIdentifier(commandName)
	return [`# Provider stubs for ${commandName}. Move useful functions to share/rush/completions/${safeFileName(commandName)}.rush.`, ...dynamic.map((note, index) => [``, `# ${note.path}: ${note.reason}`, `function __rush_complete_${safe}_todo_${index + 1}() {`, `    # TODO: hand-port from Fig source using read-only commands only.`, `    return 0`, `}`].join('\n'))].join('\n') + '\n'
}

function parseFigSpec(source: string): ParseResult {
	const notes: ParseNote[] = []
	const objectStart = findSpecObjectStart(source)
	if (objectStart < 0) return { value: undefined, notes: [{ path: '', reason: 'could not find completionSpec object' }] }
	const parser = new StaticParser(source, objectStart, notes)
	return { value: parser.parseValue(''), notes }
}

function findSpecObjectStart(source: string): number {
	const completionSpec = source.indexOf('completionSpec')
	if (completionSpec >= 0) {
		const equals = source.indexOf('=', completionSpec)
		if (equals >= 0) {
			const brace = source.indexOf('{', equals)
			if (brace >= 0) return brace
		}
	}
	const exportDefault = source.indexOf('export default')
	if (exportDefault >= 0) {
		const brace = source.indexOf('{', exportDefault)
		if (brace >= 0) return brace
	}
	return -1
}

const unsupported = Symbol('unsupported')

class StaticParser {
	constructor(private readonly source: string, private index: number, private readonly notes: ParseNote[]) {}

	parseValue(where: string): unknown {
		this.skipSpaceAndComments()
		const ch = this.source[this.index]
		if (ch === '{') return this.parseObject(where)
		if (ch === '[') return this.parseArray(where)
		if (ch === '"' || ch === "'") return this.parseString()
		if (this.source.startsWith('true', this.index) && !isIdent(this.source[this.index + 4])) return this.takeLiteral(true, 4)
		if (this.source.startsWith('false', this.index) && !isIdent(this.source[this.index + 5])) return this.takeLiteral(false, 5)
		if (this.source.startsWith('null', this.index) && !isIdent(this.source[this.index + 4])) return this.takeLiteral(null, 4)
		if (/[0-9-]/.test(ch ?? '')) return this.parseNumber()
		const start = this.index
		this.skipExpression()
		this.notes.push({ path: where, reason: 'unsupported expression skipped', snippet: this.source.slice(start, this.index) })
		return unsupported
	}

	private parseObject(where: string): Record<string, unknown> {
		const object: Record<string, unknown> = {}
		this.index += 1
		while (this.index < this.source.length) {
			this.skipSpaceAndComments()
			if (this.source[this.index] === '}') {
				this.index += 1
				break
			}
			if (this.source.startsWith('...', this.index)) {
				const start = this.index
				this.index += 3
				this.skipExpression()
				this.notes.push({ path: where, reason: 'object spread requires hand conversion', snippet: this.source.slice(start, this.index) })
				this.consumeComma()
				continue
			}
			const key = this.parseKey()
			if (!key) {
				const start = this.index
				this.skipExpression()
				this.notes.push({ path: where, reason: 'unsupported object member skipped', snippet: this.source.slice(start, this.index) })
				this.consumeComma()
				continue
			}
			this.skipSpaceAndComments()
			if (this.source[this.index] !== ':') {
				this.notes.push({ path: appendPath(where, key), reason: 'shorthand property skipped' })
				this.skipExpression()
				this.consumeComma()
				continue
			}
			this.index += 1
			const value = this.parseValue(appendPath(where, key))
			if (value !== unsupported) object[key] = value
			this.consumeComma()
		}
		return object
	}

	private parseArray(where: string): unknown[] {
		const array: unknown[] = []
		this.index += 1
		let item = 0
		while (this.index < this.source.length) {
			this.skipSpaceAndComments()
			if (this.source[this.index] === ']') {
				this.index += 1
				break
			}
			if (this.source.startsWith('...', this.index)) {
				const start = this.index
				this.index += 3
				this.skipExpression()
				this.notes.push({ path: `${where}[${item}]`, reason: 'array spread requires hand conversion', snippet: this.source.slice(start, this.index) })
			} else {
				const value = this.parseValue(`${where}[${item}]`)
				if (value !== unsupported) array.push(value)
			}
			item += 1
			this.consumeComma()
		}
		return array
	}

	private parseKey(): string | undefined {
		this.skipSpaceAndComments()
		const ch = this.source[this.index]
		if (ch === '"' || ch === "'") return this.parseString()
		if (/[A-Za-z_$]/.test(ch ?? '')) {
			const start = this.index
			this.index += 1
			while (/[A-Za-z0-9_$]/.test(this.source[this.index] ?? '')) this.index += 1
			return this.source.slice(start, this.index)
		}
		return undefined
	}

	private parseString(): string {
		const quote = this.source[this.index]
		this.index += 1
		let out = ''
		while (this.index < this.source.length) {
			const ch = this.source[this.index]
			if (ch === quote) {
				this.index += 1
				break
			}
			if (ch === '\\') {
				const next = this.source[this.index + 1]
				if (next === 'n') out += '\n'
				else if (next === 't') out += '\t'
				else if (next === 'r') out += '\r'
				else out += next ?? ''
				this.index += 2
			} else {
				out += ch
				this.index += 1
			}
		}
		return out
	}

	private parseNumber(): unknown {
		const match = this.source.slice(this.index).match(/^-?\d+(?:\.\d+)?/)
		if (!match) return unsupported
		this.index += match[0].length
		return Number(match[0])
	}

	private takeLiteral(value: unknown, length: number): unknown {
		this.index += length
		return value
	}

	private consumeComma() {
		this.skipSpaceAndComments()
		if (this.source[this.index] === ',') this.index += 1
	}

	private skipSpaceAndComments() {
		while (this.index < this.source.length) {
			while (/\s/.test(this.source[this.index] ?? '')) this.index += 1
			if (this.source.startsWith('//', this.index)) {
				this.index = this.source.indexOf('\n', this.index + 2)
				if (this.index < 0) this.index = this.source.length
				continue
			}
			if (this.source.startsWith('/*', this.index)) {
				const end = this.source.indexOf('*/', this.index + 2)
				this.index = end < 0 ? this.source.length : end + 2
				continue
			}
			break
		}
	}

	private skipExpression() {
		let paren = 0
		let brace = 0
		let bracket = 0
		while (this.index < this.source.length) {
			const ch = this.source[this.index]
			if (ch === '"' || ch === "'" || ch === '`') {
				this.skipQuoted(ch)
				continue
			}
			if (this.source.startsWith('//', this.index) || this.source.startsWith('/*', this.index)) {
				this.skipSpaceAndComments()
				continue
			}
			if (ch === '(') paren += 1
			else if (ch === ')') {
				if (paren > 0) paren -= 1
			}
			else if (ch === '{') brace += 1
			else if (ch === '}') {
				if (brace === 0 && paren === 0 && bracket === 0) break
				if (brace > 0) brace -= 1
			}
			else if (ch === '[') bracket += 1
			else if (ch === ']') {
				if (bracket === 0 && paren === 0 && brace === 0) break
				if (bracket > 0) bracket -= 1
			}
			else if (ch === ',' && paren === 0 && brace === 0 && bracket === 0) break
			this.index += 1
		}
	}

	private skipQuoted(quote: string) {
		this.index += 1
		while (this.index < this.source.length) {
			const ch = this.source[this.index]
			if (ch === '\\') this.index += 2
			else if (ch === quote) {
				this.index += 1
				break
			} else this.index += 1
		}
	}
}

function appendPath(base: string, key: string): string {
	return base ? `${base}.${key}` : key
}

function stringArray(value: unknown): string[] {
	if (typeof value === 'string') return [value]
	if (Array.isArray(value)) return value.filter((item): item is string => typeof item === 'string')
	return []
}

function arrayOfObjects(value: unknown): Record<string, unknown>[] {
	if (!Array.isArray(value)) return []
	return value.filter(isObject)
}

function isObject(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isRushName(value: string): boolean {
	return /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(value)
}

function safeValueName(value: string): string {
	return value.trim().replace(/\s+/g, '-') || 'value'
}

function safeFileName(value: string): string {
	return value.replace(/^@/, '').replace(/[^A-Za-z0-9_.-]+/g, '-').replace(/^-+|-+$/g, '') || 'command'
}

function safeIdentifier(value: string): string {
	return safeFileName(value).replace(/[^A-Za-z0-9_]/g, '_').replace(/^[0-9]/, '_$&')
}

function cleanDescription(value: string): string {
	return oneLine(value).slice(0, 160)
}

function oneLine(value: string): string {
	return value.replace(/\s+/g, ' ').trim()
}

function clampPriority(value: number): number {
	return Math.max(-128, Math.min(127, Math.trunc(value)))
}

function isIdent(ch: string | undefined): boolean {
	return /[A-Za-z0-9_$]/.test(ch ?? '')
}
