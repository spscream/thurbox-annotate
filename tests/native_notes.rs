use ratatui::{
    backend::{Backend, TestBackend},
    Terminal,
};
use thurbox::kernel::{
    host::{KeyPress, LuaHost, Published, RenderContext},
    node::Node,
    registry::Registry,
    snapshot::Snapshot,
    theme::Themes,
};

fn publish(host: &LuaHost, focus: &str) {
    let snapshot = &Snapshot::default();
    let themes = &Themes::load(None);
    let mut registry = Registry::default();
    let (bindings, settings) = host.declarations();
    registry.declare(bindings, settings);
    let diffs = thurbox::kernel::diff::DiffStore::new();
    let repos = thurbox::kernel::repos::RepoStore::with_hosts(Default::default());
    host.publish(&Published {
        epoch: thurbox::kernel::host::Epoch::always_fresh(),
        snapshot,
        attach_errors: &Default::default(),
        inflight: &[],
        themes,
        registry: &registry,
        diffs: &diffs,
        links: &Default::default(),
        content: &Default::default(),
        meta: &Default::default(),
        metrics: &Default::default(),
        status_rows: 0,
        can_open: true,
        inventory: &[],
        ui_dir: "ui",
        settings: &Default::default(),
        repos: &repos,
        wants: &Default::default(),
        focus: Some(focus),
        selection: Some("synthetic quote\n    second line"),
        hovered: None,
        printing: &Default::default(),
    })
    .expect("publish");
}

fn key(host: &LuaHost, name: &str, ch: Option<char>, shift: bool) {
    assert!(host
        .on_key(
            host.index_of("notes").unwrap(),
            &KeyPress {
                name: name.into(),
                ch,
                shift,
                ..Default::default()
            }
        )
        .unwrap());
}
fn type_text(host: &LuaHost, text: &str) {
    for ch in text.chars() {
        if ch == '\n' {
            key(host, "enter", None, true);
        } else {
            key(host, &ch.to_string(), Some(ch), false);
        }
    }
}
fn node(host: &LuaHost, w: u16, h: u16) -> std::rc::Rc<Node> {
    host.render(
        host.index_of("notes").unwrap(),
        RenderContext {
            width: w,
            height: h,
            focused: true,
            elapsed: 0.0,
            frame: 0,
        },
    )
    .unwrap()
    .node
}
fn paint(host: &LuaHost, w: u16, h: u16) -> (String, ratatui::layout::Position) {
    let tree = node(host, w, h);
    let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
    terminal
        .draw(|f| {
            thurbox::kernel::paint::render(
                f,
                f.area(),
                &tree,
                &thurbox::kernel::paint::PlaceholderSurfaces,
            )
        })
        .unwrap();
    let caret = terminal.backend_mut().get_cursor_position().unwrap();
    assert!(
        caret.x > 0 && caret.x < w - 1 && caret.y > 0 && caret.y < h - 1,
        "caret {caret:?} outside editor {w}x{h}"
    );
    let buf = terminal.backend().buffer();
    let text = (0..h)
        .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect::<String>())
        .collect::<Vec<_>>()
        .join("\n");
    (text, caret)
}
fn screen(host: &LuaHost, w: u16, h: u16) -> String {
    paint(host, w, h).0
}
fn f2(host: &LuaHost, focus: &str) {
    let mut registry = Registry::default();
    let (bindings, settings) = host.declarations();
    registry.declare(bindings, settings);
    let binding = registry
        .resolve(
            &KeyPress {
                name: "f2".into(),
                ..Default::default()
            },
            Some(focus),
        )
        .expect("F2 binding");
    assert_eq!(binding.action, "notes.comment");
    assert!(host
        .on_action(host.index_of(&binding.plugin).unwrap(), &binding.action)
        .unwrap());
    assert!(
        registry
            .resolve(
                &KeyPress {
                    name: "esc".into(),
                    ..Default::default()
                },
                Some("agent")
            )
            .is_none(),
        "notes must not globally claim Escape"
    );
}
fn saved(tree: &Node, comment: &str) -> bool {
    match tree {
        Node::Text { lines, .. } => lines
            .iter()
            .flatten()
            .any(|run| run.text == format!("     {comment}")),
        Node::Box { children, .. } => children.iter().any(|child| saved(child, comment)),
        _ => false,
    }
}
#[test]
fn notes_editor_and_return_regression() {
    let host = LuaHost::new(std::env::var("ANNOTATE_UI").expect("assembled UI"));
    assert!(host.error.is_none(), "{:?}", host.error);
    publish(&host, "agent");
    f2(&host, "agent");
    publish(&host, "notes");
    if std::env::var_os("ANNOTATE_BASELINE").is_some() {
        type_text(&host, &"длинный комментарий ".repeat(30));
        screen(&host, 32, 10);
        return;
    }
    let text = (1..=30)
        .map(|i| format!("строка {i}: длинный комментарий с переносами"))
        .collect::<Vec<_>>()
        .join("\n")
        + "\nХВОСТ";
    type_text(&host, &text);
    let tail = screen(&host, 32, 10);
    assert!(tail.contains("ХВОСТ"));
    println!("MULTILINE 32x10 caret={:?}\n{tail}", paint(&host, 32, 10).1);
    for (w, h) in [(16, 6), (60, 18), (12, 4), (80, 24)] {
        assert!(screen(&host, w, h).contains("ХВОСТ"));
    }
    key(&host, "home", None, false);
    assert!(screen(&host, 32, 10).contains("строка 1:"));
    key(&host, "down", None, false);
    key(&host, "up", None, false);
    key(&host, "end", None, false);
    key(&host, "backspace", None, false);
    type_text(&host, "Т");
    assert!(screen(&host, 32, 10).contains("ХВОСТ"));
    // F2 leaves the editor without clearing it, and re-entry resumes it.
    host.drain_commands();
    f2(&host, "notes");
    assert!(format!("{:?}", host.drain_commands()).contains("toggle: true"));
    publish(&host, "agent");
    f2(&host, "agent");
    publish(&host, "notes");
    assert!(screen(&host, 32, 10).contains("ХВОСТ"));
    key(&host, "enter", None, false);
    assert!(saved(&node(&host, 80, 24), &text));
    publish(&host, "agent");
    f2(&host, "agent");
    publish(&host, "notes");
    type_text(&host, "abcdef");
    key(&host, "home", None, false);
    key(&host, "enter", None, true);
    key(&host, "backspace", None, false); // delete the inserted line break
    key(&host, "end", None, false);
    let bottom = paint(&host, 8, 6).1;
    key(&host, "up", None, false);
    let above = paint(&host, 8, 6).1;
    assert!(
        above.y < bottom.y,
        "Up must cross the soft-wrap boundary: {above:?} vs {bottom:?}"
    );
    key(&host, "down", None, false);
    assert!(paint(&host, 8, 6).1.y > above.y);
    key(&host, "esc", None, false);
    // Both active and archived lists leave through native focus memory.
    for archive in [false, true] {
        if archive {
            key(&host, "tab", None, false);
        }
        host.drain_commands();
        key(&host, "esc", None, false);
        assert!(format!("{:?}", host.drain_commands()).contains("toggle: true"));
        f2(&host, "notes");
        assert!(format!("{:?}", host.drain_commands()).contains("toggle: true"));
    }
    key(&host, "tab", None, false);
    publish(&host, "agent");
    f2(&host, "agent");
    publish(&host, "notes");
    type_text(&host, &"абвгд ".repeat(100));
    assert!(screen(&host, 20, 8).contains("абвгд"));
    println!("SOFT WRAP 20x8\n{}", screen(&host, 20, 8));
    key(&host, "esc", None, false); // existing explicit cancel discards compose only
    assert!(saved(&node(&host, 80, 24), &text));
    println!("PASS: multiline, soft wrap, Cyrillic, resize, navigation, editing, save/cancel, F2 draft resume, list Escape/F2 command wiring");
}
