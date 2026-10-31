//! Rust NSH components. Signals update retained native views; no JavaScript VM.
use crate::{
    model::{Champion, Preferences, Theme, phase_label},
    platform,
    service::{self, Command, State},
};
use nsh_core::element::{desktop, input, on_key, set_clipboard};
use nsh_core::prelude::*;
use std::time::Duration;

#[derive(Clone, Copy)]
struct Colors {
    bg: u32,
    surface: u32,
    subtle: u32,
    border: u32,
    text: u32,
    muted: u32,
    accent: u32,
    on_accent: u32,
    danger: u32,
}
fn colors(theme: Theme) -> Colors {
    match theme {
        Theme::ClassicGold => Colors {
            bg: 0x0a0a0a,
            surface: 0x171717,
            subtle: 0x262626,
            border: 0x393939,
            text: 0xfafafa,
            muted: 0xa1a1a1,
            accent: 0xd6b773,
            on_accent: 0x181715,
            danger: 0xff6467,
        },
        Theme::ChatgptDark => Colors {
            bg: 0x171717,
            surface: 0x212121,
            subtle: 0x303030,
            border: 0x4a4a4a,
            text: 0xf5f5f5,
            muted: 0xb4b4b4,
            accent: 0xffffff,
            on_accent: 0x171717,
            danger: 0xff8080,
        },
        Theme::ChatgptLight => Colors {
            bg: 0xf7f7f8,
            surface: 0xffffff,
            subtle: 0xeeeeef,
            border: 0xd0d0d5,
            text: 0x202123,
            muted: 0x606067,
            accent: 0x202123,
            on_accent: 0xffffff,
            danger: 0xb42318,
        },
        Theme::Nord => Colors {
            bg: 0x2e3440,
            surface: 0x3b4252,
            subtle: 0x434c5e,
            border: 0x5a657c,
            text: 0xeceff4,
            muted: 0xd8dee9,
            accent: 0x88c0d0,
            on_accent: 0x2e3440,
            danger: 0xe58e97,
        },
        Theme::Catppuccin => Colors {
            bg: 0x181825,
            surface: 0x1e1e2e,
            subtle: 0x313244,
            border: 0x585b70,
            text: 0xcdd6f4,
            muted: 0xa6adc8,
            accent: 0xcba6f7,
            on_accent: 0x1e1e2e,
            danger: 0xf38ba8,
        },
    }
}
fn palette(state: Signal<State>) -> Colors {
    state.with(|s| colors(s.prefs.theme))
}
fn label(value: impl IntoReactive<SharedString>, state: Signal<State>) -> Text {
    text(value)
        .text_size(px(14.))
        .text_color(move || rgb(palette(state).text))
}
fn muted(value: impl IntoReactive<SharedString>, state: Signal<State>) -> Text {
    label(value, state)
        .text_size(px(12.))
        .text_color(move || rgb(palette(state).muted))
}
fn heading(value: impl IntoReactive<SharedString>, state: Signal<State>) -> Text {
    label(value, state)
        .text_size(px(20.))
        .font_weight(FontWeight::SEMIBOLD)
}
fn button(
    value: impl IntoReactive<SharedString>,
    state: Signal<State>,
    action: impl Fn() + 'static,
) -> View {
    view()
        .h(px(34.))
        .px(px(12.))
        .rounded(px(7.))
        .flex_row()
        .items_center()
        .justify_center()
        .bg(move || rgb(palette(state).subtle))
        .role(AccessibilityRole::Button)
        .focusable(true)
        .hover(|s| s.opacity(0.8))
        .focus(|s| {
            s.outline(px(2.))
                .outline_offset(px(2.))
                .outline_color(move || rgb(palette(state).accent))
        })
        .active(|s| s.opacity(0.65))
        .disabled_style(|s| s.opacity(0.35))
        .on_press(action)
        .child(label(value, state))
}
fn update(state: Signal<State>, change: impl FnOnce(&mut Preferences)) {
    let mut prefs = service::global().read().prefs;
    change(&mut prefs);
    service::global().configure(prefs.clone());
    state.update(|s| s.prefs = prefs);
}
fn state_signal() -> Signal<State> {
    let state = signal(service::global().read());
    set_interval(Duration::from_millis(100), move || {
        let next = service::global().read();
        if state.get_untracked() != next {
            state.set(next);
        }
    });
    state
}
fn switch(label_text: &'static str, state: Signal<State>, accept: bool) -> View {
    let checked = move || {
        state.with(|s| {
            if accept {
                s.prefs.auto_accept
            } else {
                s.prefs.auto_pick
            }
        })
    };
    view()
        .flex_row()
        .items_center()
        .gap(px(12.))
        .child(label(label_text, state).font_weight(FontWeight::MEDIUM))
        .child(
            view()
                .w(px(42.))
                .h(px(24.))
                .p(px(3.))
                .rounded(px(12.))
                .bg(move || {
                    rgb(if checked() {
                        palette(state).accent
                    } else {
                        palette(state).border
                    })
                })
                .role(AccessibilityRole::Switch)
                .label(label_text)
                .focusable(true)
                .accessibility_state(move || AccessibilityState {
                    checked: Some(if checked() {
                        nsh_core::Checked::True
                    } else {
                        nsh_core::Checked::False
                    }),
                    ..Default::default()
                })
                .focus(|s| {
                    s.outline(px(2.))
                        .outline_offset(px(2.))
                        .outline_color(move || rgb(palette(state).accent))
                })
                .on_press(move || {
                    update(state, |p| {
                        if accept {
                            p.auto_accept = !p.auto_accept
                        } else {
                            p.auto_pick = !p.auto_pick
                        }
                    })
                })
                .child(
                    view()
                        .size(px(18.))
                        .rounded(px(9.))
                        .ml(move || px(if checked() { 18. } else { 0. }))
                        .bg(move || {
                            rgb(if checked() {
                                palette(state).on_accent
                            } else {
                                palette(state).muted
                            })
                        }),
                ),
        )
}
fn title_bar(state: Signal<State>) -> View {
    view()
        .h(px(40.))
        .min_h(px(40.))
        .flex_row()
        .items_center()
        .px(px(16.))
        .gap(px(8.))
        .window_drag(true)
        .bg(move || rgb(palette(state).surface))
        .child(traffic(
            state,
            0xff5f57,
            "隐藏到托盘",
            desktop::close_window,
        ))
        .child(traffic(state, 0xfebc2e, "最小化", desktop::minimize))
        .child(traffic(
            state,
            0x28c840,
            "最大化或还原",
            desktop::toggle_maximize,
        ))
        .child(view().flex_1())
        .child(image(platform::icon_path().to_string_lossy().into_owned()).size(px(22.)))
        .child(label("Catengar", state).font_weight(FontWeight::MEDIUM))
        .child(view().flex_1())
        .child(view().w(px(52.)))
}
fn traffic(
    state: Signal<State>,
    color: u32,
    name: &'static str,
    action: impl Fn() + 'static,
) -> View {
    view()
        .size(px(16.))
        .rounded(px(8.))
        .bg(rgb(color))
        .window_drag(false)
        .role(AccessibilityRole::Button)
        .label(name)
        .tooltip(
            text(name)
                .p(px(6.))
                .bg(rgb(0x303030))
                .text_color(rgb(0xffffff)),
        )
        .focusable(true)
        .focus(|s| {
            s.outline(px(2.))
                .outline_offset(px(2.))
                .outline_color(move || rgb(palette(state).accent))
        })
        .on_press(action)
}
#[component]
pub fn App() -> impl IntoElement {
    let state = state_signal();
    let page = signal(0u8);
    let search = signal(String::new());
    let about = signal(false);
    on_key("Escape", move |_| {
        if about.get_untracked() {
            about.set(false);
        } else {
            page.set(0);
        }
    });
    view()
        .flex_1()
        .font_family("Microsoft YaHei UI")
        .bg(move || rgb(palette(state).bg))
        .text_color(move || rgb(palette(state).text))
        .child(title_bar(state))
        .child(
            view()
                .flex_1()
                .min_h(px(0.))
                .p(px(24.))
                .gap(px(16.))
                .child(
                    view()
                        .flex_row()
                        .items_center()
                        .gap(px(10.))
                        .child(heading("Catengar", state))
                        .child(muted(format!("v{}", crate::display_version()), state))
                        .child(muted("League 助手", state).flex_1())
                        .child(when(
                            move || state.with(|s| s.update.available()),
                            move || button("发现新版本", state, move || page.set(2)),
                        ))
                        .child(
                            when(
                                move || page.get() == 0,
                                move || {
                                    view()
                                        .flex_row()
                                        .gap(px(8.))
                                        .child(button("日志", state, move || page.set(1)))
                                        .child(button("设置", state, move || page.set(2)))
                                },
                            )
                            .otherwise(move || button("返回", state, move || page.set(0))),
                        ),
                )
                .child(when(
                    move || state.with(|s| !s.snapshot.settings_error.is_empty()),
                    move || {
                        label(
                            move || state.with(|s| s.snapshot.settings_error.clone()),
                            state,
                        )
                        .text_color(move || rgb(palette(state).danger))
                    },
                ))
                .child(when(
                    move || state.with(|s| s.snapshot.auth_retry),
                    move || {
                        view()
                            .flex_row()
                            .gap(px(12.))
                            .items_center()
                            .child(
                                label(move || state.with(|s| s.snapshot.status.clone()), state)
                                    .flex_1(),
                            )
                            .child(button("授权连接", state, || {
                                service::global().command(Command::Authorize)
                            }))
                    },
                ))
                .child(when(move || page.get() == 0, move || home(state, search)))
                .child(when(move || page.get() == 1, move || logs(state)))
                .child(when(
                    move || page.get() == 2,
                    move || settings(state, about),
                ))
                .child(footer(state)),
        )
        .child(when(
            move || about.get(),
            move || {
                nsh_base::dialog()
                    .on_cancel(move || about.set(false))
                    .on_close(move || about.set(false))
                    .items_center()
                    .justify_center()
                    .bg(rgba(0x00000099))
                    .child(
                        view()
                            .w(px(440.))
                            .p(px(28.))
                            .gap(px(16.))
                            .rounded(px(12.))
                            .bg(move || rgb(palette(state).surface))
                            .child(heading("关于 Catengar", state))
                            .child(label(
                                "League Client 本地助手，帮助接受对局与优先选择英雄。",
                                state,
                            ))
                            .child(muted(
                                format!("版本 {} · 作者 0xruth1ezz", crate::VERSION),
                                state,
                            ))
                            .child(button("打开 GitHub", state, || {
                                platform::open_url("https://github.com/0xruth1ezz/lcu-catengar")
                            }))
                            .child(button("关闭", state, move || about.set(false))),
                    )
            },
        ))
}
fn home(state: Signal<State>, search: Signal<String>) -> View {
    let filtered = computed(move || {
        state.with(|s| {
            s.snapshot
                .champions
                .iter()
                .filter(|c| c.matches(&search.get()))
                .cloned()
                .collect::<Vec<_>>()
        })
    });
    let columns = signal(6u32);
    let list_ref = element_ref();
    view().flex_1().min_h(px(0.)).gap(px(16.))
        .child(view().flex_row().items_center().justify_between().child(switch("自动接受对局",state,true))
            .child(muted("关闭窗口后仍在托盘运行",state)))
        .child(view().flex_1().min_h(px(0.)).p(px(18.)).gap(px(14.)).rounded(px(12.)).bg(move||rgb(palette(state).surface))
            .child(switch("自动选取英雄",state,false))
            .child(nsh_base::checkbox().checked(move||state.with(|s|s.prefs.always_prioritize))
                .on_change(move|v:&bool|update(state,|p|p.always_prioritize = *v))
                .focus(|s|s.outline(px(2.)).outline_offset(px(2.)).outline_color(move||rgb(palette(state).accent)))
                .flex_row().items_center().gap(px(8.))
                .indicator_class("w-4 h-4 rounded border items-center justify-center")
                .indicator_style(move |s| s.border_color(rgb(palette(state).muted)).bg(rgb(if state.with(|s|s.prefs.always_prioritize){palette(state).accent}else{palette(state).surface})))
                .indicator(text(move||if state.with(|s|s.prefs.always_prioritize){"✓"}else{""}).text_size(px(12.)).text_color(move||rgb(palette(state).on_accent)))
                .child(label("总是按照优先顺序选取英雄",state)))
            .child(view().h(px(1.)).bg(move||rgb(palette(state).border)))
            .child(view().flex_row().flex_1().min_h(px(0.)).gap(px(20.))
                .child(view().flex_1().min_w(px(0.)).gap(px(12.))
                    .child(view().flex_row().items_center().child(label("英雄库",state).font_weight(FontWeight::SEMIBOLD).flex_1()).child(muted(move||format!("{} 位英雄",filtered.with(Vec::len)),state)))
                    .child(input().value(move||search.get()).placeholder("搜索英雄名称或英文名").label("搜索英雄")
                        .on_change(move|v:&str|{search.set(v.to_owned());list_ref.scroll_to(point(px(0.),px(0.)),false);})
                        .h(px(38.)).px(px(12.)).rounded(px(7.)).bg(move||rgb(palette(state).subtle)).text_color(move||rgb(palette(state).text)).placeholder_color(move||Hsla::from(rgb(palette(state).muted))).caret_color(move||Hsla::from(rgb(palette(state).accent))))
                    .child(virtual_list(move||filtered.with(Vec::len),move|at|{
                        let champion=computed(move||filtered.with(|c|c.get(at.index()).cloned()).unwrap_or_default());
                        champion_tile(state,champion)
                    }).columns(move||columns.get()).estimated_item_size(px(122.)).content_padding(px(2.)).element_ref(&list_ref).flex_1()
                        .on_layout(move|b:&Bounds<Points>|{let count=(b.size.width.0/92.).floor().max(2.) as u32;if columns.get_untracked()!=count{columns.set(count);}})
                        .empty(view().p(px(28.)).gap(px(10.)).child(label(move||if search.get().is_empty(){"等待英雄资料"}else{"没有找到英雄"},state))
                            .child(muted(move||if search.get().is_empty(){"连接 League 客户端后，英雄库会自动加载。已缓存的优先英雄可以离线编辑。"}else{"试试客户端语言的名称或英文名。"},state)))))
                .child(view().w(px(270.)).min_w(px(270.)).gap(px(10.))
                    .child(view().flex_row().items_center().child(label("优先顺序",state).font_weight(FontWeight::SEMIBOLD).flex_1()).child(muted(move||state.with(|s|format!("{} / 32",s.prefs.priority.len())),state)))
                    .child(muted("排在前面的英雄优先选取",state))
                    .child(scroll().flex_1().child(view().gap(px(6.)).child(each(move||state.with(|s|s.prefs.priority.clone()),|id|*id,move|id,rank|priority_row(state,id,rank)))
                        .child(when(move||state.with(|s|s.prefs.priority.is_empty()),move||view().py(px(28.)).gap(px(8.)).child(label("还没有优先英雄",state)).child(muted("点击头像右上角的添加按钮，开始设置。",state)))))))))
        .child(when(move||state.with(|s|s.snapshot.phase=="ChampSelect"),move||view().flex_row().gap(px(12.)).child(label(move||state.with(|s|format!("当前英雄：{}",s.snapshot.name(s.snapshot.current))),state))
            .child(muted(move||state.with(|s|if s.snapshot.pick_supported==Some(false){"当前模式不执行自动选取".into()}else if s.snapshot.pick_completed&&!s.prefs.always_prioritize{"本轮优选已完成".into()}else{format!("可用替补：{}",s.snapshot.bench.iter().map(|id|s.snapshot.name(*id)).collect::<Vec<_>>().join("、"))}),state))))
}
fn portrait(state: Signal<State>, champion: Memo<Champion>, size: f32) -> View {
    view()
        .size(px(size))
        .rounded(px(7.))
        .overflow_hidden()
        .bg(move || rgb(palette(state).subtle))
        .items_center()
        .justify_center()
        .child(
            when(
                move || champion.with(|c| c.portrait.is_empty()),
                move || {
                    muted(
                        move || champion.with(|c| c.name.chars().take(2).collect::<String>()),
                        state,
                    )
                },
            )
            .otherwise(move || {
                image(move || {
                    champion.with(|c| {
                        state.with(|s| {
                            s.snapshot
                                .root
                                .join(&c.portrait)
                                .to_string_lossy()
                                .into_owned()
                        })
                    })
                })
                .size(px(size))
                .object_fit(ResizeMode::Cover)
            }),
        )
}
fn champion_tile(state: Signal<State>, champion: Memo<Champion>) -> View {
    let selected = move || state.with(|s| s.prefs.priority.contains(&champion.get().id));
    view()
        .h(px(122.))
        .items_center()
        .gap(px(5.))
        .p(px(5.))
        .tooltip(
            label(
                move || champion.with(|c| format!("{} · {}", c.name, c.alias)),
                state,
            )
            .p(px(8.))
            .bg(move || rgb(palette(state).subtle)),
        )
        .child(
            view()
                .size(px(76.))
                .child(portrait(state, champion, 76.))
                .child(
                    button(
                        move || if selected() { "✓" } else { "+" },
                        state,
                        move || update(state, |p| p.toggle(champion.get_untracked().id)),
                    )
                    .absolute()
                    .top(px(-2.))
                    .right(px(-2.))
                    .w(px(28.))
                    .h(px(28.))
                    .px(px(0.))
                    .label(move || {
                        champion.with(|c| {
                            format!("{}{}", if selected() { "移除" } else { "添加" }, c.name)
                        })
                    })
                    .disabled(move || !selected() && state.with(|s| s.prefs.priority.len() >= 32)),
                ),
        )
        .child(
            button("查看", state, move || {
                platform::open_detail(champion.get_untracked())
            })
            .h(px(28.))
            .bg(move || rgb(palette(state).surface)),
        )
}
fn priority_row(state: Signal<State>, id: ReadSignal<i32>, rank: ReadSignal<usize>) -> View {
    let champion = computed(move || {
        state
            .with(|s| {
                s.snapshot
                    .champions
                    .iter()
                    .find(|c| c.id == id.get())
                    .cloned()
            })
            .unwrap_or_else(|| Champion {
                id: id.get(),
                name: format!("英雄 {}", id.get()),
                ..Default::default()
            })
    });
    view()
        .flex_row()
        .items_center()
        .gap(px(7.))
        .py(px(4.))
        .child(muted(move || format!("{:02}", rank.get() + 1), state).w(px(22.)))
        .child(portrait(state, champion, 34.))
        .child(
            label(move || champion.with(|c| c.name.clone()), state)
                .flex_1()
                .number_of_lines(1),
        )
        .child(
            button("↑", state, move || {
                update(state, |p| p.reorder(id.get_untracked(), true))
            })
            .w(px(26.))
            .px(px(0.))
            .label("提高优先级")
            .disabled(move || rank.get() == 0),
        )
        .child(
            button("↓", state, move || {
                update(state, |p| p.reorder(id.get_untracked(), false))
            })
            .w(px(26.))
            .px(px(0.))
            .label("降低优先级")
            .disabled(move || state.with(|s| rank.get() + 1 >= s.prefs.priority.len())),
        )
        .child(
            button("×", state, move || {
                update(state, |p| p.toggle(id.get_untracked()))
            })
            .w(px(26.))
            .px(px(0.))
            .label("移除优先英雄"),
        )
}
fn footer(state: Signal<State>) -> View {
    let profile = computed(move || {
        state.with(|s| Champion {
            name: s.snapshot.profile.name.clone(),
            portrait: s.snapshot.profile.portrait.clone(),
            ..Default::default()
        })
    });
    view()
        .flex_row()
        .items_center()
        .gap(px(12.))
        .child(view().size(px(7.)).rounded(px(4.)).bg(move || {
            rgb(if state.with(|s| s.snapshot.connected) {
                0x4ade80
            } else {
                palette(state).muted
            })
        }))
        .child(muted(move || state.with(|s| s.snapshot.status.clone()), state).flex_1())
        .child(when(
            move || state.with(|s| s.snapshot.connected),
            move || {
                view()
                    .flex_row()
                    .items_center()
                    .gap(px(10.))
                    .child(portrait(state, profile, 28.))
                    .child(
                        button(
                            move || state.with(|s| s.snapshot.profile.riot_id.clone()),
                            state,
                            move || {
                                set_clipboard(state.with(|s| s.snapshot.profile.riot_id.clone()))
                            },
                        )
                        .label("复制好友 ID"),
                    )
                    .child(muted(
                        move || state.with(|s| phase_label(&s.snapshot.phase).to_owned()),
                        state,
                    ))
            },
        ))
}
fn settings(state: Signal<State>, about: Signal<bool>) -> View {
    let diagnostics = signal(false);
    view()
        .flex_1()
        .min_h(px(0.))
        .rounded(px(12.))
        .bg(move || rgb(palette(state).surface))
        .p(px(20.))
        .child(
            scroll().flex_1().child(
                view()
                    .gap(px(24.))
                    .child(heading("设置", state))
                    .child(
                        view()
                            .gap(px(12.))
                            .child(label("外观", state).font_weight(FontWeight::SEMIBOLD))
                            .child(muted("立即生效，自动保存", state))
                            .child(view().flex_row().flex_wrap().gap(px(8.)).children(
                                Theme::ALL.into_iter().map(move |theme| {
                                    button(theme.label(), state, move || {
                                        update(state, |p| p.theme = theme)
                                    })
                                    .border_1()
                                    .border_color(move || {
                                        rgb(if state.with(|s| s.prefs.theme == theme) {
                                            palette(state).accent
                                        } else {
                                            palette(state).border
                                        })
                                    })
                                }),
                            )),
                    )
                    .child(
                        view()
                            .gap(px(10.))
                            .child(label("软件更新", state).font_weight(FontWeight::SEMIBOLD))
                            .child(label(
                                move || state.with(|s| s.update.description().to_owned()),
                                state,
                            ))
                            .child(
                                view()
                                    .flex_row()
                                    .gap(px(10.))
                                    .child(
                                        button("检查更新", state, || {
                                            service::global().command(Command::CheckUpdate)
                                        })
                                        .disabled(move || state.with(|s| s.update.busy())),
                                    )
                                    .child(when(
                                        move || state.with(|s| s.update.available()),
                                        move || {
                                            button("更新并重启", state, || {
                                                service::global().command(Command::InstallUpdate)
                                            })
                                            .disabled(
                                                move || state.with(|s| !s.snapshot.can_install()),
                                            )
                                        },
                                    )),
                            )
                            .child(when(
                                move || state.with(|s| !s.snapshot.can_install()),
                                move || muted("匹配或对局期间暂缓安装更新。", state),
                            )),
                    )
                    .child(
                        view()
                            .flex_row()
                            .gap(px(10.))
                            .child(button("重新连接", state, || {
                                service::global().command(Command::Reconnect)
                            }))
                            .child(button("关于 Catengar", state, move || about.set(true))),
                    )
                    .child(button(
                        move || {
                            if diagnostics.get() {
                                "收起诊断信息"
                            } else {
                                "展开诊断信息"
                            }
                        },
                        state,
                        move || diagnostics.update(|v| *v = !*v),
                    ))
                    .child(when(
                        move || diagnostics.get(),
                        move || {
                            view()
                                .gap(px(8.))
                                .child(muted(
                                    move || {
                                        state.with(|s| {
                                            format!(
                                                "英雄 {} · 头像 {} · 符文 {} · 符文系 {}",
                                                s.snapshot.champions.len(),
                                                s.snapshot
                                                    .champions
                                                    .iter()
                                                    .filter(|c| !c.portrait.is_empty())
                                                    .count(),
                                                s.snapshot.perks,
                                                s.snapshot.styles
                                            )
                                        })
                                    },
                                    state,
                                ))
                                .child(muted(
                                    move || {
                                        state.with(|s| {
                                            format!(
                                                "本次已接受 {} 场 · 已确认选取 {} 次",
                                                s.snapshot.accepted, s.snapshot.swapped
                                            )
                                        })
                                    },
                                    state,
                                ))
                                .child(muted(
                                    move || {
                                        state.with(|s| {
                                            format!("数据目录：{}", s.snapshot.root.display())
                                        })
                                    },
                                    state,
                                ))
                        },
                    )),
            ),
        )
}
fn logs(state: Signal<State>) -> View {
    let page = signal(crate::journal::Page::default());
    let offset = signal(0usize);
    let anchor = signal(None::<usize>);
    let confirm = signal(false);
    let request = stored(Some(service::global().journal.page(0)));
    let last_offset = stored(usize::MAX);
    let ticks = stored(0u32);
    let clearing = stored(None::<crossbeam_channel::Receiver<bool>>);
    let notice = signal(String::new());
    set_interval(Duration::from_millis(100), move || {
        if let Some(rx) = request.get()
            && let Ok(next) = rx.try_recv()
        {
            if next.offset == offset.get_untracked() {
                page.set(next);
            }
            request.replace(None);
        }
        if let Some(rx) = clearing.get()
            && let Ok(ok) = rx.try_recv()
        {
            clearing.replace(None);
            notice.set(
                if ok {
                    "历史日志已清空。"
                } else {
                    "日志清空失败，请检查目录权限。"
                }
                .into(),
            );
            last_offset.replace(usize::MAX);
            offset.set(0);
            anchor.set(None);
        }
        let tick = ticks.get() + 1;
        ticks.replace(tick);
        if request.get().is_none()
            && (last_offset.get() != offset.get_untracked()
                || (offset.get_untracked() == 0 && tick.is_multiple_of(20)))
        {
            if offset.get_untracked() == 0 {
                anchor.set(None);
            } else if anchor.get_untracked().is_none() {
                anchor.set(Some(page.get_untracked().total));
            }
            request.replace(Some(
                service::global()
                    .journal
                    .page_at(offset.get_untracked(), anchor.get_untracked()),
            ));
            last_offset.replace(offset.get_untracked());
        }
    });
    view()
        .flex_1()
        .min_h(px(0.))
        .rounded(px(12.))
        .bg(move || rgb(palette(state).surface))
        .p(px(20.))
        .gap(px(12.))
        .child(
            view()
                .flex_row()
                .gap(px(10.))
                .items_center()
                .child(heading("活动日志", state).flex_1())
                .child(button("打开日志目录", state, || {
                    platform::reveal_logs()
                }))
                .child(button("清空所有日志", state, move || {
                    confirm.set(true)
                })),
        )
        .child(muted("本地时间 · 新记录在前 · 自动保存在本机", state))
        .child(when(
            move || confirm.get(),
            move || {
                view()
                    .flex_row()
                    .gap(px(10.))
                    .items_center()
                    .child(label("清空全部历史日志？此操作无法撤销。", state).flex_1())
                    .child(button("取消", state, move || confirm.set(false)))
                    .child(button("确认清空", state, move || {
                        confirm.set(false);
                        clearing.replace(Some(service::global().journal.clear()));
                    }))
            },
        ))
        .child(label(move || notice.get(), state))
        .child(
            label(move || page.with(|p| p.error.clone()), state)
                .text_color(move || rgb(palette(state).danger)),
        )
        .child(
            scroll().flex_1().child(
                view()
                    .gap(px(10.))
                    .child(each(
                        move || page.with(|p| p.entries.clone()),
                        |e| (e.timestamp.clone(), e.kind.clone(), e.message.clone()),
                        move |entry, _| {
                            view()
                                .flex_row()
                                .gap(px(16.))
                                .py(px(8.))
                                .border_b_1()
                                .border_color(move || rgb(palette(state).border))
                                .child(
                                    view()
                                        .w(px(180.))
                                        .gap(px(5.))
                                        .child(muted(
                                            move || entry.with(|e| e.timestamp.clone()),
                                            state,
                                        ))
                                        .child(muted(
                                            move || entry.with(|e| e.kind_label().to_owned()),
                                            state,
                                        )),
                                )
                                .child(
                                    label(move || entry.with(|e| e.message.clone()), state)
                                        .flex_1()
                                        .text_color(move || {
                                            rgb(if entry.with(|e| e.level == "failure") {
                                                palette(state).danger
                                            } else {
                                                palette(state).text
                                            })
                                        }),
                                )
                        },
                    ))
                    .child(when(
                        move || page.with(|p| p.entries.is_empty()),
                        move || {
                            muted(
                                "暂无日志。连接变化、自动接受和选取结果会记录在这里。",
                                state,
                            )
                        },
                    )),
            ),
        )
        .child(
            view()
                .flex_row()
                .gap(px(8.))
                .items_center()
                .child(
                    muted(
                        move || page.with(|p| format!("共 {} 条记录", p.total)),
                        state,
                    )
                    .flex_1(),
                )
                .child(button("最新", state, move || offset.set(0)))
                .child(
                    button("较新", state, move || {
                        offset.update(|v| *v = v.saturating_sub(20))
                    })
                    .disabled(move || offset.get() == 0),
                )
                .child(
                    button("较早", state, move || offset.update(|v| *v += 20))
                        .disabled(move || page.with(|p| offset.get() + 20 >= p.total)),
                ),
        )
}
#[component]
pub fn Details() -> impl IntoElement {
    let state = state_signal();
    let champion = platform::detail_champion();
    let id = champion.id;
    let url = format!("https://haidou.pro/champion/{id}/");
    let page_ref = element_ref();
    let loading = signal(true);
    let error = signal(false);
    let generation = signal(0u32);
    on_key("Escape", move |_| desktop::close_window());
    view()
        .flex_1()
        .p(px(16.))
        .gap(px(12.))
        .font_family("Microsoft YaHei UI")
        .bg(move || rgb(palette(state).surface))
        .child(
            view()
                .flex_row()
                .items_center()
                .gap(px(8.))
                .child(heading(champion.name, state).flex_1())
                .child(button("刷新网页", state, move || page_ref.reload()))
                .child(button("浏览器打开", state, move || {
                    platform::open_url(&format!("https://haidou.pro/champion/{id}/"))
                }))
                .child(button("关闭", state, desktop::close_window)),
        )
        .child(label("haidou.pro", state).text_color(move || rgb(palette(state).accent)))
        .child(when(
            move || loading.get() && !error.get(),
            move || muted("正在加载英雄资料…", state),
        ))
        .child(when(
            move || error.get(),
            move || {
                view()
                    .gap(px(10.))
                    .child(label(
                        "网页无法加载。请检查网络与 Microsoft Edge WebView2 Runtime。",
                        state,
                    ))
                    .child(button("重试", state, move || {
                        error.set(false);
                        loading.set(true);
                        generation.update(|g| *g += 1);
                    }))
            },
        ))
        .child(dynamic(move || {
            let _ = generation.get();
            web_view(url.clone())
                .element_ref(&page_ref)
                .flex_1()
                .on_load_start(move |_: &WebNavigation| loading.set(true))
                .on_load(move |_: &WebNavigation| loading.set(false))
                .on_error(move |_: &str| {
                    error.set(true);
                    loading.set(false);
                })
        }))
}
#[component]
pub fn Toast() -> impl IntoElement {
    let state = state_signal();
    let message = platform::toast_message();
    view()
        .flex_1()
        .p(px(18.))
        .gap(px(10.))
        .bg(move || rgb(palette(state).surface))
        .font_family("Microsoft YaHei UI")
        .child(
            view()
                .flex_row()
                .items_center()
                .child(label("Catengar", state).flex_1())
                .child(button("关闭", state, desktop::close_window)),
        )
        .child(label(message, state).font_weight(FontWeight::MEDIUM))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn luminance(color: u32) -> f64 {
        let linear = |shift: u32| {
            let s = ((color >> shift) & 255u32) as f64 / 255.;
            if s <= 0.04045 {
                s / 12.92
            } else {
                ((s + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
    fn contrast(a: u32, b: u32) -> f64 {
        let (a, b) = (luminance(a), luminance(b));
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }
    #[test]
    fn warnings_and_focus_contrast_in_all_palettes() {
        for theme in Theme::ALL {
            let c = colors(theme);
            assert!(contrast(c.danger, c.bg) >= 4.5, "warning {theme:?}");
            for background in [c.bg, c.surface, c.subtle] {
                assert!(contrast(c.accent, background) >= 3., "focus {theme:?}");
            }
        }
    }
}
