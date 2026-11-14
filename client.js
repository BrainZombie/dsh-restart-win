/**
 * dsh-restart-win —— 浏览器半端（右栏「DSH 重启」面板）。
 *
 * 面板只做三件事：看状态、发动作、看回显。
 *   - 状态：hostKind / 实测端口 / 主进程与宿主 pid / HTTP / profile / 版本，8 秒自动刷新；
 *   - 动作：刷新、演练、深度验证、安全重启、只停、只拉；危险动作要点两次确认；
 *   - 回显：动作触发的 detached run 用 runId 轮询结果文件，逐步渲染引擎的 steps，
 *     并把最近的 restart-history 摘要列在下面。重启会把宿主杀掉，所以 runId 存在
 *     localStorage 里，面板重载后继续轮询同一个 run。
 *
 * 走宿主同源 cookie，不额外拿 token。本文件是手工维护的 __ModuleLoader__ bundle
 * （与 dsh-card-library 同一约定），不含 JSX；改完 `node --check client.js`。
 */
// 宿主在某些安装形态下会把同一个 bundle 执行两次（scoped link: 包实测）：第二次会触发
// client-modules 的 duplicate factory registration，整个插件被丢弃。这里做幂等。
if (!window.__dshRestartWinBundleLoaded) {
window.__dshRestartWinBundleLoaded = true
window.__ModuleLoader__.load({
  // 必须是**包名**：client 加载器按 manifest 的 id（= 包名）把 factory 与插件记录对上，
  // 写成短名只会注册 factory、永远不调用 apply（实测：面板不出现且没有任何报错）。
  id: '@brainzombie/dsh-restart-win',
  factory(require) {
    var React = require('react')
    var h = React.createElement

    var ID = 'dsh-restart-win'
    var PREFIX = '/dsh-restart-win'
    var STORE_KEY = 'dsh-restart-win.run'

    // 只用 DSH 的主题 token，深浅色都跟。
    var C = {
      text: 'var(--dsw-alias-label-primary, CanvasText)',
      dim: 'var(--dsw-alias-label-secondary, GrayText)',
      line: 'var(--dsw-alias-border-l2, rgba(128,128,128,0.28))',
      brand: 'var(--dsw-alias-brand-primary, #4b7bec)',
      ok: 'var(--dsw-alias-state-success-primary, #2f9e44)',
      warn: 'var(--dsw-alias-state-warn-primary, #e8590c)',
      danger: 'var(--dsw-alias-state-error-primary, #e03131)',
      soft: 'var(--dsw-alias-bg-layer-2, rgba(128,128,128,0.09))',
      soft2: 'var(--dsw-alias-bg-layer-3, rgba(128,128,128,0.15))',
    }
    var MONO = 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace'

    // ─────────────────────────────────────────────────────── 小工具
    function Glyph(size) {
      return h('svg', {
        viewBox: '0 0 16 16', width: size || 16, height: size || 16, fill: 'none',
        stroke: 'currentColor', strokeWidth: 1.35, strokeLinecap: 'round', strokeLinejoin: 'round',
        'aria-hidden': true, style: { display: 'block' },
      },
        h('path', { d: 'M13.2 6.4 A5.4 5.4 0 1 0 13.4 9.6' }),
        h('path', { d: 'M13.4 2.9 V6.6 H9.7' }),
        h('path', { d: 'M8 5.6 V8.2 L9.9 9.4' }))
    }

    function text(value, fallback) {
      if (value === null || value === undefined || value === '') return fallback === undefined ? '—' : fallback
      return String(value)
    }

    function fmtTime(iso) {
      if (!iso) return '—'
      var d = new Date(iso)
      if (isNaN(d.getTime())) return String(iso)
      var pad = function (n) { return n < 10 ? '0' + n : '' + n }
      return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
        pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds())
    }

    function api(path, options) {
      return fetch(PREFIX + path, options).then(function (res) {
        return res.json().then(function (payload) { return payload }).catch(function () {
          return { ok: false, error: 'HTTP ' + res.status }
        })
      })
    }

    function envelopeOf(value) {
      if (!value) return null
      if (value.envelope && typeof value.envelope === 'object') return value.envelope
      if (value.detail && value.detail.envelope && typeof value.detail.envelope === 'object') return value.detail.envelope
      return null
    }

    function stepsOf(value) {
      var env = envelopeOf(value)
      if (env && Array.isArray(env.steps)) return env.steps
      if (value && Array.isArray(value.steps)) return value.steps
      return []
    }

    // ─────────────────────────────────────────────────────── 样式
    var S = {
      root: { display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0, fontSize: 12, color: C.text },
      scroll: { overflowY: 'auto', padding: '10px 12px 18px', display: 'flex', flexDirection: 'column', gap: 10 },
      card: { border: '1px solid ' + C.line, borderRadius: 8, background: C.soft, padding: '10px 12px' },
      row: { display: 'flex', justifyContent: 'space-between', gap: 10, padding: '2px 0' },
      label: { color: C.dim },
      value: { fontFamily: MONO, textAlign: 'right', wordBreak: 'break-all' },
      buttons: { display: 'flex', flexWrap: 'wrap', gap: 6 },
      btn: {
        border: '1px solid ' + C.line, background: C.soft2, color: C.text, borderRadius: 6,
        padding: '5px 10px', fontSize: 12, cursor: 'pointer', lineHeight: 1.3,
      },
      btnPrimary: {
        border: '1px solid ' + C.brand, background: C.brand, color: '#fff', borderRadius: 6,
        padding: '5px 10px', fontSize: 12, cursor: 'pointer', lineHeight: 1.3,
      },
      btnDanger: {
        border: '1px solid ' + C.danger, background: 'transparent', color: C.danger, borderRadius: 6,
        padding: '5px 10px', fontSize: 12, cursor: 'pointer', lineHeight: 1.3,
      },
      btnOff: { opacity: 0.45, cursor: 'default' },
      sectionTitle: { fontWeight: 600, marginBottom: 6 },
      log: {
        fontFamily: MONO, fontSize: 11, lineHeight: 1.5, whiteSpace: 'pre-wrap', wordBreak: 'break-word',
        maxHeight: 260, overflowY: 'auto', background: C.soft, borderRadius: 6, padding: '8px 10px',
      },
      ok: { color: C.ok },
      warn: { color: C.warn },
      danger: { color: C.danger },
      dim: { color: C.dim },
      chip: {
        display: 'inline-block', padding: '1px 6px', borderRadius: 999, border: '1px solid ' + C.line,
        fontSize: 10.5, color: C.dim, marginLeft: 6,
      },
    }

    // ─────────────────────────────────────────────────────── 状态卡
    function StatusCard(props) {
      var state = props.state
      if (state.loading && !state.value) {
        return h('div', { style: S.card }, h('div', { style: S.dim }, '读取状态…'))
      }
      if (state.error && !state.value) {
        return h('div', { style: S.card },
          h('div', { style: S.danger }, '读状态失败：' + state.error))
      }
      var value = state.value || {}
      var status = value.status || {}
      var inst = Array.isArray(status.instances) && status.instances.length ? status.instances[0] : null
      var okState = value.ok === true
      var rows = [
        ['宿主形态', status.hostKind === 'desktop' ? 'DSH Desktop（Electron）' : 'dsh web'],
        ['端口', text(status.port) + (status.configuredPort !== undefined ? '（配置 ' + text(status.configuredPort) + '，来源 ' + text(status.portSource) + '）' : '')],
        ['主进程', text(status.mainPid)],
        ['宿主进程', inst ? text(inst.pid) + ' · ' + text(inst.source) : '未发现'],
        ['HTTP', text(status.http) + (status.serving ? '（服务中）' : '（无响应）')],
        ['profile', text(status.profile)],
        ['版本', text(status.version)],
      ]
      return h('div', { style: S.card },
        h('div', { style: S.row },
          h('div', { style: S.sectionTitle }, '当前实例'),
          h('div', { style: okState ? S.ok : S.danger }, okState ? 'ok' : text(value.error, 'failed'))),
        rows.map(function (pair) {
          return h('div', { key: pair[0], style: S.row },
            h('span', { style: S.label }, pair[0]),
            h('span', { style: S.value }, pair[1]))
        }),
        status.launchUrl ? h('div', { style: { marginTop: 6, display: 'flex', gap: 6, alignItems: 'center' } },
          h('span', { style: S.label }, '访问地址'),
          h('code', { style: { fontFamily: MONO, fontSize: 10.5, wordBreak: 'break-all', flex: 1 } }, status.launchUrl),
          h('button', {
            style: S.btn,
            onClick: function () {
              try { navigator.clipboard.writeText(status.launchUrl) } catch (e) { /* ignore */ }
            },
          }, '复制')) : null,
        state.error ? h('div', { style: { marginTop: 6, color: C.warn } }, '刷新告警：' + state.error) : null)
    }

    // ─────────────────────────────────────────────────────── 动作回显
    function RunCard(props) {
      var run = props.run
      if (!run) return null
      var value = run.value || {}
      var steps = stepsOf(value)
      var state = run.running ? 'running' : (value.state || (value.ok ? 'ok' : 'failed'))
      var color = state === 'ok' ? S.ok : (state === 'running' ? S.dim : S.danger)
      return h('div', { style: S.card },
        h('div', { style: S.row },
          h('div', { style: S.sectionTitle }, '动作：' + (run.label || '—')),
          h('div', { style: color }, state + (value.exitCode !== undefined && value.exitCode !== null ? ' · exit ' + value.exitCode : ''))),
        run.runId ? h('div', { style: { ...S.row, fontSize: 11 } },
          h('span', { style: S.label }, 'runId'),
          h('span', { style: { fontFamily: MONO } }, run.runId)) : null,
        run.waitingHost ? h('div', { style: S.warn }, '宿主正在重启，等待结果文件…') : null,
        value.summary ? h('div', { style: S.row },
          h('span', { style: S.label }, '结论'),
          h('span', { style: S.value }, String(value.summary))) : null,
        value.error || (value.ok === false && !value.summary) ? h('div', { style: S.danger },
          '错误：' + text(value.error, '未知')) : null,
        steps.length ? h('div', { style: S.log },
          steps.slice(-30).map(function (step, index) {
            var mark = step.state === 'ok' ? '✓' : (step.state === 'warn' ? '!' : (step.state === 'skip' ? '·' : '✗'))
            var color2 = step.state === 'ok' ? C.ok : (step.state === 'warn' ? C.warn : (step.state === 'skip' ? C.dim : C.danger))
            return h('div', { key: index, style: { color: color2 } },
              mark + ' ' + text(step.step) + '  ' + text(step.detail, ''))
          })) : h('div', { style: S.dim }, run.running ? '等待引擎写入步骤…' : '没有步骤输出。'),
        value.resultFile ? h('div', { style: { ...S.row, fontSize: 10.5 } },
          h('span', { style: S.label }, '结果文件'),
          h('span', { style: { fontFamily: MONO, wordBreak: 'break-all' } }, value.resultFile)) : null)
    }

    // ─────────────────────────────────────────────────────── 历史
    function HistoryCard(props) {
      var entries = props.entries
      return h('div', { style: S.card },
        h('div', { style: S.sectionTitle }, '最近重启'),
        !entries || !entries.length ? h('div', { style: S.dim }, '暂无记录。') :
          entries.map(function (entry, index) {
            var color = entry.result === 'restarted-ok' ? S.ok : (entry.rc === 0 ? S.dim : S.danger)
            return h('div', { key: index, style: { ...S.row, fontSize: 11 } },
              h('span', { style: { fontFamily: MONO } }, fmtTime(entry.ts)),
              h('span', { style: color },
                text(entry.result) + (entry.rc !== null ? ' · rc ' + entry.rc : '') +
                (entry.port ? ' · 端口 ' + entry.port : '') +
                (entry.newPid ? ' · 新宿主 ' + entry.newPid : '')))
          }))
    }

    // ─────────────────────────────────────────────────────── 面板
    function Panel() {
      var statusState = React.useState({ loading: true, error: null, value: null })
      var status = statusState[0]
      var setStatus = statusState[1]

      var runState = React.useState(null)
      var run = runState[0]
      var setRun = runState[1]

      var busyState = React.useState('')
      var busy = busyState[0]
      var setBusy = busyState[1]

      var confirmState = React.useState('')
      var confirm = confirmState[0]
      var setConfirm = confirmState[1]

      var historyState = React.useState([])
      var history = historyState[0]
      var setHistory = historyState[1]

      var timer = React.useRef(null)
      var alive = React.useRef(true)

      var refresh = React.useCallback(function () {
        api('/api/status').then(function (payload) {
          if (!alive.current) return
          if (!payload || typeof payload !== 'object') payload = { ok: false, error: '空响应' }
          setStatus({ loading: false, error: payload.ok === true ? null : text(payload.error, 'status failed'), value: payload })
          if (payload.ok === true && payload.status) {
            var kinds = payload.status.hostKind
            var p = payload.status.resolvedPort || payload.status.port
            if (kinds && p) { /* no-op: kept for readability */ }
          }
        }).catch(function (err) {
          if (!alive.current) return
          setStatus(function (prev) {
            return { loading: false, error: String((err && err.message) || err), value: prev ? prev.value : null }
          })
        })
        api('/api/history?limit=5').then(function (payload) {
          if (alive.current && payload && Array.isArray(payload.entries)) setHistory(payload.entries)
        }).catch(function () { /* ignore */ })
      }, [])

      var stopPolling = React.useCallback(function () {
        if (timer.current) { clearTimeout(timer.current); timer.current = null }
      }, [])

      var poll = React.useCallback(function (runId, label) {
        stopPolling()
        setRun({ runId: runId, label: label, value: null, running: true, waitingHost: false })
        function tick() {
          if (!alive.current) return
          api('/api/result?runId=' + encodeURIComponent(runId) + '&waitMs=5000').then(function (payload) {
            if (!alive.current) return
            if (!payload || typeof payload !== 'object') payload = { ok: false, state: 'failed', error: '空响应' }
            setRun({ runId: runId, label: label, value: payload, running: payload.state === 'running', waitingHost: false })
            if (payload.state === 'running') {
              timer.current = setTimeout(tick, 1200)
            } else {
              try { localStorage.removeItem(STORE_KEY) } catch (e) { /* ignore */ }
              refresh()
            }
          }).catch(function () {
            if (!alive.current) return
            // 重启中宿主会短暂消失：继续等，别把一次成功的重启报成失败。
            setRun(function (prev) {
              return Object.assign({}, prev || {}, { runId: runId, label: label, running: true, waitingHost: true })
            })
            timer.current = setTimeout(tick, 2000)
          })
        }
        tick()
      }, [refresh, stopPolling])

      React.useEffect(function () {
        alive.current = true
        refresh()
        var interval = setInterval(refresh, 8000)
        var saved = null
        try { saved = localStorage.getItem(STORE_KEY) } catch (e) { saved = null }
        if (saved) poll(saved, '恢复上次运行')
        return function () {
          alive.current = false
          clearInterval(interval)
          if (timer.current) clearTimeout(timer.current)
        }
      }, [])

      function act(action) {
        if (busy) return
        if (action === 'restart' || action === 'stop') {
          if (confirm !== action) {
            setConfirm(action)
            setTimeout(function () {
              if (alive.current) setConfirm(function (prev) { return prev === action ? '' : prev })
            }, 4000)
            return
          }
          setConfirm('')
        }
        setBusy(action)
        api('/api/action', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ action: action }),
        }).then(function (payload) {
          if (!alive.current) return
          setBusy('')
          if (!payload || payload.ok !== true) {
            setRun({ runId: null, label: action, value: payload || { ok: false, error: '空响应' }, running: false, waitingHost: false })
            return
          }
          if (payload.runId) {
            try { localStorage.setItem(STORE_KEY, payload.runId) } catch (e) { /* ignore */ }
            poll(payload.runId, action)
          } else {
            setRun({ runId: null, label: action, value: payload, running: false, waitingHost: false })
            refresh()
          }
        }).catch(function (err) {
          if (!alive.current) return
          setBusy('')
          setRun({ runId: null, label: action, value: { ok: false, error: String((err && err.message) || err) }, running: false, waitingHost: false })
        })
      }

      function button(label, action, options) {
        var opts = options || {}
        var isBusy = busy === action
        var isConfirm = confirm === action
        var style = opts.danger ? S.btnDanger : (opts.primary ? S.btnPrimary : S.btn)
        if (busy || isBusy) style = Object.assign({}, style, S.btnOff)
        return h('button', {
          key: action,
          style: style,
          disabled: !!busy,
          onClick: function () { act(action) },
        }, isBusy ? label + '…' : (isConfirm ? '再点一次确认' : label))
      }

      var runningKnown = status.value && status.value.status && status.value.status.serving

      return h('div', { style: S.root },
        h('div', { style: S.scroll },
          h(StatusCard, { state: status }),
          h('div', { style: S.card },
            h('div', { style: S.sectionTitle }, '操作'),
            h('div', { style: S.buttons },
              button('刷新', 'refresh'),
              button('演练', 'dry_run'),
              button('深度验证', 'preflight'),
              button('安全重启', 'restart', { primary: true }),
              button('只停', 'stop', { danger: true }),
              button('只拉', 'start')),
            h('div', { style: { marginTop: 6, fontSize: 10.5, color: C.dim } },
              runningKnown
                ? '安全重启会先深度验证，再杀 Electron 主进程整棵树并重放 exe；当前会话会中断，重启后可续跑。'
                : '没有发现运行中的宿主：安全重启会走冷启动（需要 boot-record 或 App 路径）。')),
          h(RunCard, { run: run }),
          h(HistoryCard, { entries: history })))
    }

    // 面板里任何一次抛错都在面板内显示，而不是留一个空白栏。
    class PanelBoundary extends React.Component {
      constructor(props) {
        super(props)
        this.state = { error: null }
      }

      static getDerivedStateFromError(error) {
        return { error: error }
      }

      render() {
        if (!this.state.error) return this.props.children
        var message = String((this.state.error && this.state.error.message) || this.state.error)
        return h('div', { style: { padding: '14px 16px', fontSize: 12, color: C.danger } },
          'DSH 重启面板出错：' + message)
      }
    }

    function Guarded() {
      return h(PanelBoundary, null, h(Panel))
    }

    function ChipTitle() {
      return h('span', { style: { fontSize: 12 } }, 'DSH 重启')
    }

    function definition() {
      return {
        id: ID,
        kind: ID,
        keepMounted: true,
        title: function () { return 'DSH 重启' },
        guide: [{
          id: ID,
          order: 64,
          title: function () { return 'DSH 重启' },
          description: function () { return '安全重启 DSH Desktop：状态、演练、深度验证、重启与结果回显' },
          icon: Glyph,
        }],
      }
    }

    return {
      inject: ['slots', 'sidebarRightTabs'],
      apply(ctx) {
        ctx.effect(function () { return ctx.sidebarRightTabs.register(definition()) },
          'dsh-restart-win: tab type')
        ctx.effect(function () {
          return ctx.slots.inject('sidebar.right.pane.tab', function () {
            return ctx.slots.register({ name: 'sidebar.right.pane.tab', key: ID }, Guarded)
          })
        }, 'dsh-restart-win: tab body')
        ctx.effect(function () {
          return ctx.slots.inject('sidebar.right.pane.tab.title', function () {
            return ctx.slots.register({ name: 'sidebar.right.pane.tab.title', key: ID }, ChipTitle)
          })
        }, 'dsh-restart-win: tab title')
      },
    }
  },
})

}
