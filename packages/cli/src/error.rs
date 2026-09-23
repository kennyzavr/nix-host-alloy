use std::fmt;

#[derive(Debug, Clone)]
pub struct ErrorCollection<E> {
    pub errors: Vec<E>,
}

impl<E> Default for ErrorCollection<E> {
    fn default() -> Self {
        Self { errors: vec![] }
    }
}

impl<E> ErrorCollection<E> {
    pub fn new(errors: Vec<E>) -> Self {
        Self { errors }
    }

    pub fn push(&mut self, error: E) {
        self.errors.push(error);
    }

    pub fn is_empty(&self) -> bool {
        self.errors.is_empty()
    }

    pub fn len(&self) -> usize {
        self.errors.len()
    }

    pub fn into_inner(self) -> Vec<E> {
        self.errors
    }
}

impl<E: fmt::Display> fmt::Display for ErrorCollection<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (i, err) in self.errors.iter().enumerate() {
            if i > 0 {
                writeln!(f)?;
            }
            let err_str = err.to_string();
            for (j, line) in err_str.lines().enumerate() {
                if j == 0 {
                    write!(f, " - {}", line)?;
                } else {
                    write!(f, "\n   {}", line)?;
                }
            }
        }
        Ok(())
    }
}

impl<E: std::error::Error + fmt::Debug + 'static> std::error::Error for ErrorCollection<E> {}

impl<E> From<Vec<E>> for ErrorCollection<E> {
    fn from(errors: Vec<E>) -> Self {
        Self { errors }
    }
}

impl<E> IntoIterator for ErrorCollection<E> {
    type Item = E;
    type IntoIter = std::vec::IntoIter<E>;

    fn into_iter(self) -> Self::IntoIter {
        self.errors.into_iter()
    }
}

impl<'a, E> IntoIterator for &'a ErrorCollection<E> {
    type Item = &'a E;
    type IntoIter = std::slice::Iter<'a, E>;

    fn into_iter(self) -> Self::IntoIter {
        self.errors.iter()
    }
}

#[derive(Debug)]
pub struct WrappedError<E> {
    pub context: String,
    pub source: E,
}

impl<E: fmt::Display> fmt::Display for WrappedError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.context)
    }
}

impl<E: std::error::Error + 'static> std::error::Error for WrappedError<E> {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.source)
    }
}

pub trait WrapErrExt<T, E> {
    fn wrap_err<C>(self, context: C) -> Result<T, WrappedError<E>>
    where
        C: fmt::Display + Send + Sync + 'static;

    fn wrap_err_with<C, F>(self, f: F) -> Result<T, WrappedError<E>>
    where
        C: fmt::Display + Send + Sync + 'static,
        F: FnOnce() -> C;
}

impl<T, E> WrapErrExt<T, E> for Result<T, E> {
    fn wrap_err<C>(self, context: C) -> Result<T, WrappedError<E>>
    where
        C: fmt::Display + Send + Sync + 'static,
    {
        self.map_err(|source| WrappedError {
            context: context.to_string(),
            source,
        })
    }

    fn wrap_err_with<C, F>(self, f: F) -> Result<T, WrappedError<E>>
    where
        C: fmt::Display + Send + Sync + 'static,
        F: FnOnce() -> C,
    {
        self.map_err(|source| WrappedError {
            context: f().to_string(),
            source,
        })
    }
}

pub fn render_error_chain(err: &dyn std::error::Error) -> String {
    let mut result = String::new();
    let mut current_err = Some(err);

    while let Some(e) = current_err {
        if !result.is_empty() {
            result.push('\n');
        }

        let err_str = e.to_string();
        for (i, line) in err_str.lines().enumerate() {
            if i == 0 {
                if line.starts_with(" - ") {
                    result.push_str(line);
                } else {
                    result.push_str(&format!(" - {}", line));
                }
            } else {
                if line.starts_with("   ") || line.starts_with(" - ") {
                    result.push_str(&format!("\n{}", line));
                } else {
                    result.push_str(&format!("\n   {}", line));
                }
            }
        }

        current_err = e.source();
    }

    result
}

#[derive(Debug)]
pub struct StringError(pub String);

impl fmt::Display for StringError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for StringError {}

pub fn err_msg<S: Into<String>>(msg: S) -> StringError {
    StringError(msg.into())
}
