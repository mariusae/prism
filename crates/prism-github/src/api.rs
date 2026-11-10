//! GitHub's REST API: who a token is, and the repositories it can reach.

use crate::http::{HttpClient, Request, Response};
use crate::Error;
use serde::Deserialize;

const API: &str = "https://api.github.com";

/// A request to GitHub's API, with the headers it asks for.
pub fn api_request(method: &'static str, path: &str, token: &str) -> Request {
    Request::new(method, format!("{API}{path}"))
        .bearer(token)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .header("User-Agent", "prism-sync")
}

/// A GitHub account.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct User {
    pub id: u64,
    pub login: String,
    #[serde(default)]
    pub name: Option<String>,
}

impl User {
    /// The address GitHub keeps private for the account: what commits
    /// are made as, so a real address is never written into history.
    pub fn noreply_email(&self) -> String {
        format!("{}+{}@users.noreply.github.com", self.id, self.login)
    }

    /// The name commits are made under: the account's name, else its login.
    pub fn display_name(&self) -> &str {
        self.name.as_deref().filter(|n| !n.trim().is_empty()).unwrap_or(&self.login)
    }
}

/// A repository, as GitHub describes it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Repo {
    /// GitHub's id for it: renamed or moved, still the one.
    pub id: u64,
    /// `owner/name`.
    pub full_name: String,
    #[serde(default)]
    pub private: bool,
    #[serde(default = "default_branch")]
    pub default_branch: String,
    #[serde(default)]
    pub clone_url: String,
}

fn default_branch() -> String {
    "main".into()
}

/// Whether text is a repository's `owner/name` and nothing more: safe to
/// put in a URL's path.
pub fn is_full_name(text: &str) -> bool {
    let valid = |part: &str| !part.is_empty() && part != "." && part != ".." && part.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
    matches!(text.split_once('/'), Some((owner, name)) if valid(owner) && valid(name))
}

/// `owner/name`, from a GitHub remote's address: `https://github.com/o/n.git`,
/// `git@github.com:o/n.git`, `ssh://git@github.com/o/n`. `None` for a
/// remote that is not on GitHub.
pub fn repository_from_remote(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("http://github.com/"))
        .or_else(|| url.strip_prefix("git@github.com:"))
        .or_else(|| url.strip_prefix("ssh://git@github.com/"))
        // `https://user:token@github.com/…`: what is before the `@` must be
        // credentials, not another host with `@github.com/` in its path.
        .or_else(|| {
            let (credentials, rest) = url.strip_prefix("https://")?.split_once("@github.com/")?;
            (!credentials.contains('/')).then_some(rest)
        })?;
    let rest = rest.trim_end_matches('/');
    let name = rest.strip_suffix(".git").unwrap_or(rest);
    is_full_name(name).then(|| name.to_owned())
}

/// The address a repository is cloned from, over HTTPS.
pub fn clone_url(full_name: &str) -> String {
    format!("https://github.com/{full_name}.git")
}

// --- Requests and their answers ---------------------------------------------

/// Asks who a token is.
pub fn user_request(token: &str) -> Request {
    api_request("GET", "/user", token)
}

pub fn parse_user(response: &Response) -> Result<User, Error> {
    expect_success(response)?.json()
}

/// Asks about a repository — which also answers whether the token may
/// read it. `full_name` must pass [`is_full_name`].
pub fn repo_request(token: &str, full_name: &str) -> Request {
    api_request("GET", &format!("/repos/{full_name}"), token)
}

pub fn parse_repo(response: &Response) -> Result<Repo, Error> {
    expect_success(response)?.json()
}

/// Asks to make a repository on the token's own account.
pub fn create_repo_request(token: &str, name: &str, private: bool) -> Request {
    api_request("POST", "/user/repos", token).json(&serde_json::json!({ "name": name, "private": private, "auto_init": false }))
}

/// Asks which installations of a GitHub App the token's user can reach.
pub fn installations_request(token: &str) -> Request {
    api_request("GET", "/user/installations?per_page=100", token)
}

pub fn parse_installations(response: &Response) -> Result<Vec<u64>, Error> {
    #[derive(Deserialize)]
    struct Installation {
        id: u64,
    }
    #[derive(Deserialize)]
    struct Page {
        installations: Vec<Installation>,
    }
    Ok(expect_success(response)?.json::<Page>()?.installations.into_iter().map(|i| i.id).collect())
}

/// Asks for the repositories an installation was given, a page of 100 at
/// a time, from page 1.
pub fn installation_repos_request(token: &str, installation: u64, page: u32) -> Request {
    api_request("GET", &format!("/user/installations/{installation}/repositories?per_page=100&page={page}"), token)
}

pub fn parse_installation_repos(response: &Response) -> Result<Vec<Repo>, Error> {
    #[derive(Deserialize)]
    struct Page {
        repositories: Vec<Repo>,
    }
    Ok(expect_success(response)?.json::<Page>()?.repositories)
}

/// A response that succeeded, or the error its status means.
pub fn expect_success(response: &Response) -> Result<&Response, Error> {
    match response.status {
        200..=299 => Ok(response),
        401 => Err(Error::Unauthorized),
        403 | 404 => Err(Error::NoAccess),
        status => Err(Error::Status { status, body: response.text().chars().take(300).collect() }),
    }
}

/// GitHub's API, for whoever has an [`HttpClient`]: each call sends its
/// request and reads the answer.
pub struct Client<'a, H: HttpClient + ?Sized> {
    http: &'a H,
    token: String,
}

impl<'a, H: HttpClient + ?Sized> Client<'a, H> {
    pub fn new(http: &'a H, token: impl Into<String>) -> Self {
        Client { http, token: token.into() }
    }

    fn send(&self, request: Request) -> Result<Response, Error> {
        self.http.send(request).map_err(Error::Network)
    }

    pub fn user(&self) -> Result<User, Error> {
        parse_user(&self.send(user_request(&self.token))?)
    }

    pub fn repository(&self, full_name: &str) -> Result<Repo, Error> {
        if !is_full_name(full_name) {
            return Err(Error::Unexpected(format!("not a repository's name: {full_name}")));
        }
        parse_repo(&self.send(repo_request(&self.token, full_name))?)
    }

    pub fn create_repository(&self, name: &str, private: bool) -> Result<Repo, Error> {
        parse_repo(&self.send(create_repo_request(&self.token, name, private))?)
    }

    /// The repositories a GitHub App was given, on every account it is
    /// installed on.
    pub fn app_repositories(&self) -> Result<Vec<Repo>, Error> {
        let mut repositories = Vec::new();
        for installation in parse_installations(&self.send(installations_request(&self.token))?)? {
            for page in 1.. {
                let found = parse_installation_repos(&self.send(installation_repos_request(&self.token, installation, page))?)?;
                let last = found.len() < 100;
                repositories.extend(found);
                if last {
                    break;
                }
            }
        }
        Ok(repositories)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remotes_name_their_repository() {
        for url in [
            "https://github.com/ada/notes.git",
            "https://github.com/ada/notes",
            "https://github.com/ada/notes/",
            "git@github.com:ada/notes.git",
            "ssh://git@github.com/ada/notes.git",
            "https://x-access-token:secret@github.com/ada/notes.git",
        ] {
            assert_eq!(repository_from_remote(url).as_deref(), Some("ada/notes"), "{url}");
        }
        for url in [
            "https://gitlab.com/ada/notes.git",
            "/local/path.git",
            "https://github.com/ada",
            "https://github.com/ada/notes/extra",
            "https://evil.example/@github.com/a/b",
        ] {
            assert_eq!(repository_from_remote(url), None, "{url}");
        }
        assert_eq!(clone_url("ada/notes"), "https://github.com/ada/notes.git");
        assert!(is_full_name("ada/my.notes-2") && !is_full_name("ada/../etc") && !is_full_name("ada") && !is_full_name("a/b/c") && !is_full_name("a/b?x"));
    }

    #[test]
    fn answers_are_read_and_failures_told_apart() {
        let user = parse_user(&Response::new(200, r#"{"id": 7, "login": "ada", "name": null, "extra": true}"#)).unwrap();
        assert_eq!((user.display_name(), user.noreply_email().as_str()), ("ada", "7+ada@users.noreply.github.com"));
        let repo = parse_repo(&Response::new(
            200,
            r#"{"id": 42, "full_name": "ada/notes", "private": true, "default_branch": "trunk", "clone_url": "https://github.com/ada/notes.git"}"#,
        ))
        .unwrap();
        assert_eq!((repo.id, repo.default_branch.as_str()), (42, "trunk"));
        assert!(matches!(parse_repo(&Response::new(404, "{}")), Err(Error::NoAccess)));
        assert!(matches!(parse_user(&Response::new(401, "{}")), Err(Error::Unauthorized)));
        assert!(matches!(parse_user(&Response::new(500, "oops")), Err(Error::Status { status: 500, .. })));
        assert!(matches!(parse_user(&Response::new(200, "<html>")), Err(Error::Unexpected(_))));
    }

    #[test]
    fn the_client_pages_through_installations() {
        let http = |request: Request| -> Result<Response, String> {
            assert_eq!(request.header_value("Authorization"), Some("Bearer tok"));
            let repos = |from: u64, count: u64| {
                let list: Vec<_> = (from..from + count).map(|i| serde_json::json!({"id": i, "full_name": format!("o/r{i}")})).collect();
                Response::new(200, serde_json::json!({ "repositories": list }).to_string())
            };
            Ok(match request.url.strip_prefix("https://api.github.com").unwrap() {
                "/user/installations?per_page=100" => Response::new(200, r#"{"installations": [{"id": 1}, {"id": 2}]}"#),
                "/user/installations/1/repositories?per_page=100&page=1" => repos(0, 100),
                "/user/installations/1/repositories?per_page=100&page=2" => repos(100, 3),
                "/user/installations/2/repositories?per_page=100&page=1" => repos(500, 1),
                other => panic!("unexpected request {other}"),
            })
        };
        let repositories = Client::new(&http, "tok").app_repositories().unwrap();
        assert_eq!(repositories.len(), 104);
        assert_eq!(repositories[103].full_name, "o/r500");
        assert!(Client::new(&http, "tok").repository("not a name").is_err());
    }
}
