use std::collections::VecDeque;

#[derive(Clone, Debug, PartialEq)]
pub enum Notice {
    Message(String),
    TeamSide(u8),
}
impl Notice {
    pub fn message(&self) -> String {
        match self {
            Self::Message(message) => message.clone(),
            Self::TeamSide(1) => "🟦 本局我方为蓝色方 - by (Catengar)".into(),
            Self::TeamSide(2) => "🟥 本局我方为红色方 - by (Catengar)".into(),
            Self::TeamSide(_) => "阵营未确认".into(),
        }
    }
}
impl From<String> for Notice {
    fn from(message: String) -> Self {
        Self::Message(message)
    }
}
impl From<&str> for Notice {
    fn from(message: &str) -> Self {
        Self::Message(message.into())
    }
}

#[derive(Default)]
pub struct NoticeQueue(VecDeque<Notice>);
impl NoticeQueue {
    pub fn push(&mut self, notice: Notice) {
        if matches!(notice, Notice::TeamSide(_)) {
            self.0.retain(|n| !matches!(n, Notice::TeamSide(_)));
            self.0.push_front(notice);
        } else {
            self.0.push_back(notice);
        }
    }

    /// A team-side notice replaces the visible toast immediately.
    pub fn take(&mut self, active: bool) -> Option<Notice> {
        if !active || matches!(self.0.front(), Some(Notice::TeamSide(_))) {
            self.0.pop_front()
        } else {
            None
        }
    }
}
