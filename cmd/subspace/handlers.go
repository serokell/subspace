package main

import (
	"bytes"
	"fmt"
	"image/png"
	"io/ioutil"
	"net/http"
	"os"
	"regexp"
	"strings"

	"github.com/crewjam/saml/samlsp"
	"github.com/julienschmidt/httprouter"
	"github.com/pquerna/otp/totp"
	"golang.org/x/crypto/bcrypt"

	qrcode "github.com/skip2/go-qrcode"
)

var (
	validEmail    = regexp.MustCompile(`^[ -~]+@[ -~]+$`)
	validPassword = regexp.MustCompile(`^[ -~]{6,200}$`)
	validString   = regexp.MustCompile(`^[ -~]{1,200}$`)
	maxProfiles   = 250
)

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}

// Handles the sign in part separately from the SAML
func ssoHandler(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	session, err := samlSP.Session.GetSession(r)
	if session != nil {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}
	if err == samlsp.ErrNoSession {
		logger.Debugf("SSO: HandleStartAuthFlow")
		samlSP.HandleStartAuthFlow(w, r)
		return
	}

	logger.Debugf("SSO: unable to get session")
	samlSP.OnError(w, r, err)
	return
}

// Handles the SAML part separately from sign in
func samlHandler(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	if samlSP == nil {
		logger.Warnf("SAML is not configured")
		http.NotFound(w, r)
		return
	}
	logger.Debugf("SSO: samlSP.ServeHTTP")
	samlSP.ServeHTTP(w, r)
}

func wireguardQRConfigHandler(w *Web) {
	profile, err := config.FindProfile(w.ps.ByName("profile"))
	if err != nil {
		http.NotFound(w.w, w.r)
		return
	}
	if !w.Admin && profile.UserID != w.User.ID {
		Error(w.w, fmt.Errorf("failed to view config: permission denied"))
		return
	}

	b, err := ioutil.ReadFile(profile.WireGuardConfigPath())
	if err != nil {
		Error(w.w, err)
		return
	}

	img, err := qrcode.Encode(string(b), qrcode.Medium, 256)
	if err != nil {
		Error(w.w, err)
		return
	}

	w.w.Header().Set("Content-Type", "image/png")
	w.w.Header().Set("Content-Length", fmt.Sprintf("%d", len(img)))
	if _, err := w.w.Write(img); err != nil {
		Error(w.w, err)
		return
	}
}

func wireguardConfigHandler(w *Web) {
	profile, err := config.FindProfile(w.ps.ByName("profile"))
	if err != nil {
		http.NotFound(w.w, w.r)
		return
	}
	if !w.Admin && profile.UserID != w.User.ID {
		Error(w.w, fmt.Errorf("failed to view config: permission denied"))
		return
	}

	b, err := ioutil.ReadFile(profile.WireGuardConfigPath())
	if err != nil {
		Error(w.w, err)
		return
	}

	w.w.Header().Set("Content-Disposition", "attachment; filename="+profile.WireGuardConfigName())
	w.w.Header().Set("Content-Type", "application/x-wireguard-profile")
	w.w.Header().Set("Content-Length", fmt.Sprintf("%d", len(b)))
	if _, err := w.w.Write(b); err != nil {
		Error(w.w, err)
		return
	}
}

func configureHandler(w *Web) {
	if config.FindInfo().Configured {
		w.Redirect("/?error=configured")
		return
	}

	if w.r.Method == "GET" {
		w.HTML()
		return
	}

	email := strings.ToLower(strings.TrimSpace(w.r.FormValue("email")))
	emailConfirm := strings.ToLower(strings.TrimSpace(w.r.FormValue("email_confirm")))
	password := w.r.FormValue("password")

	if !validEmail.MatchString(email) || !validPassword.MatchString(password) || email != emailConfirm {
		w.Redirect("/configure?error=invalid")
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		w.Redirect("/forgot?error=bcrypt")
		return
	}
	config.UpdateInfo(func(i *Info) error {
		i.Email = email
		i.Password = hashedPassword
		i.Configured = true
		return nil
	})

	if err := w.SigninSession(true, ""); err != nil {
		Error(w.w, err)
		return
	}
	w.Redirect("/settings?success=configured")
}

func forgotHandler(w *Web) {
	if w.r.Method == "GET" {
		w.HTML()
		return
	}

	email := strings.ToLower(strings.TrimSpace(w.r.FormValue("email")))
	secret := w.r.FormValue("secret")
	password := w.r.FormValue("password")

	if email != "" && !validEmail.MatchString(email) {
		w.Redirect("/forgot?error=invalid")
		return
	}
	if secret != "" && !validString.MatchString(secret) {
		w.Redirect("/forgot?error=invalid")
		return
	}
	if email != "" && secret != "" && !validPassword.MatchString(password) {
		w.Redirect("/forgot?error=invalid&email=%s&secret=%s", email, secret)
		return
	}

	if email != config.FindInfo().Email {
		w.Redirect("/forgot?error=invalid")
		return
	}

	if secret == "" {
		secret = config.FindInfo().Secret
		if secret == "" {
			secret = RandomString(32)
			config.UpdateInfo(func(i *Info) error {
				if i.Secret == "" {
					i.Secret = secret
				}
				return nil
			})
		}

		go func() {
			if err := mailer.Forgot(email, secret); err != nil {
				logger.Error(err)
			}
		}()

		w.Redirect("/forgot?success=forgot")
		return
	}

	if secret != config.FindInfo().Secret {
		w.Redirect("/forgot?error=invalid")
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		w.Redirect("/forgot?error=bcrypt")
		return
	}
	config.UpdateInfo(func(i *Info) error {
		i.Password = hashedPassword
		i.Secret = ""
		return nil
	})

	if err := w.SigninSession(true, ""); err != nil {
		Error(w.w, err)
		return
	}
	w.Redirect("/")
}

func signoutHandler(w *Web) {
	w.SignoutSession()
	w.Redirect("/signin")
}

func signinHandler(w *Web) {
	if w.r.Method == "GET" {
		w.HTML()
		return
	}

	email := strings.ToLower(strings.TrimSpace(w.r.FormValue("email")))
	password := w.r.FormValue("password")
	passcode := w.r.FormValue("totp")

	if email != config.FindInfo().Email {
		w.Redirect("/signin?error=invalid")
		return
	}

	if err := bcrypt.CompareHashAndPassword(config.FindInfo().Password, []byte(password)); err != nil {
		w.Redirect("/signin?error=invalid")
		return
	}

	if config.FindInfo().TotpKey != "" && !totp.Validate(passcode, config.FindInfo().TotpKey) {
		// Totp has been configured and the provided code doesn't match
		w.Redirect("/signin?error=invalid")
		return
	}

	if err := w.SigninSession(true, ""); err != nil {
		Error(w.w, err)
		return
	}

	w.Redirect("/")
}

func totpQRHandler(w *Web) {
	if !w.Admin {
		Error(w.w, fmt.Errorf("failed to view config: permission denied"))
		return
	}

	if config.Info.TotpKey != "" {
		// TOTP is already configured, don't allow the current one to be leaked
		w.Redirect("/")
		return
	}

	var buf bytes.Buffer
	img, err := tempTotpKey.Image(200, 200)
	if err != nil {
		Error(w.w, err)
		return
	}

	png.Encode(&buf, img)

	w.w.Header().Set("Content-Type", "image/png")
	w.w.Header().Set("Content-Length", fmt.Sprintf("%d", len(buf.Bytes())))
	if _, err := w.w.Write(buf.Bytes()); err != nil {
		Error(w.w, err)
		return
	}

}

func userEditHandler(w *Web) {
	userID := w.ps.ByName("user")
	if userID == "" {
		userID = w.r.FormValue("user")
	}
	user, err := config.FindUser(userID)
	if err != nil {
		http.NotFound(w.w, w.r)
		return
	}
	if !w.Admin {
		Error(w.w, fmt.Errorf("failed to edit user: permission denied"))
		return
	}

	if w.r.Method == "GET" {
		w.TargetUser = user
		w.Profiles = config.ListProfilesByUser(user.ID)
		w.HTML()
		return
	}

	if w.User.ID == user.ID {
		w.Redirect("/user/edit/%s", user.ID)
		return
	}

	admin := w.r.FormValue("admin") == "yes"

	config.UpdateUser(user.ID, func(u *User) error {
		u.Admin = admin
		return nil
	})

	w.Redirect("/user/edit/%s?success=edituser", user.ID)
}

func userDeleteHandler(w *Web) {
	userID := w.ps.ByName("user")
	if userID == "" {
		userID = w.r.FormValue("user")
	}
	user, err := config.FindUser(userID)
	if err != nil {
		http.NotFound(w.w, w.r)
		return
	}
	if !w.Admin {
		Error(w.w, fmt.Errorf("failed to delete user: permission denied"))
		return
	}
	if w.User.ID == user.ID {
		w.Redirect("/user/edit/%s?error=deleteuser", user.ID)
		return
	}

	if w.r.Method == "GET" {
		w.TargetUser = user
		w.HTML()
		return
	}

	for _, profile := range config.ListProfilesByUser(user.ID) {
		if err := deleteProfile(profile); err != nil {
			logger.Errorf("delete profile failed: %s", err)
			w.Redirect("/profile/delete?error=deleteprofile")
			return
		}
	}

	if err := config.DeleteUser(user.ID); err != nil {
		Error(w.w, err)
		return
	}
	w.Redirect("/?success=deleteuser")
}

func profileAddHandler(w *Web) {
	if !w.Admin && w.User.ID == "" {
		http.NotFound(w.w, w.r)
		return
	}

	name := strings.TrimSpace(w.r.FormValue("name"))
	platform := strings.TrimSpace(w.r.FormValue("platform"))
	admin := w.r.FormValue("admin") == "yes"

	if platform == "" {
		platform = "other"
	}

	if name == "" {
		w.Redirect("/?error=profilename")
		return
	}

	var userID string
	if admin {
		userID = ""
	} else {
		userID = w.User.ID
	}

	if len(config.ListProfiles()) >= maxProfiles {
		w.Redirect("/?error=addprofile")
		return
	}

	profile, err := config.AddProfile(userID, name, platform)
	if err != nil {
		logger.Warn(err)
		w.Redirect("/?error=addprofile")
		return
	}

	script := `
	cd {{$.Datadir}}/wireguard

	wg-bond add {{$.Profile.ID}} --dns 1.1.1.1
	wg-bond conf {{$.Profile.ID}} -T subspace-root > clients/{{$.Profile.ID}}.conf

	# Syncing configuration
	wg-bond conf subspace-root > subspace.conf
	wg-quick strip ./subspace.conf > sync.conf
	wg-quick down ./subspace.conf
	wg-quick up ./subspace.conf

	`
	_, err = bash(script, struct {
		Profile Profile
		Datadir string
	}{
		profile,
		datadir,
	})
	if err != nil {
		logger.Warn(err)
		f, _ := os.Create("/tmp/error.txt")
		errstr := fmt.Sprintln(err)
		f.WriteString(errstr)
		w.Redirect("/?error=addprofile")
		return
	}

	w.Redirect("/profile/connect/%s?success=addprofile", profile.ID)
}

func profileConnectHandler(w *Web) {
	profile, err := config.FindProfile(w.ps.ByName("profile"))
	if err != nil {
		http.NotFound(w.w, w.r)
		return
	}
	if !w.Admin && profile.UserID != w.User.ID {
		Error(w.w, fmt.Errorf("failed to view profile: permission denied"))
		return
	}
	w.Profile = profile
	w.HTML()
}

func profileDeleteHandler(w *Web) {
	profileID := w.ps.ByName("profile")
	if profileID == "" {
		profileID = w.r.FormValue("profile")
	}
	profile, err := config.FindProfile(profileID)
	if err != nil {
		http.NotFound(w.w, w.r)
		return
	}
	if !w.Admin && profile.UserID != w.User.ID {
		Error(w.w, fmt.Errorf("failed to delete profile: permission denied"))
		return
	}

	if w.r.Method == "GET" {
		w.Profile = profile
		w.HTML()
		return
	}
	if err := deleteProfile(profile); err != nil {
		logger.Errorf("delete profile failed: %s", err)
		if profile.UserID == "" {
			w.Redirect("/?error=deleteprofile")
		} else {
			w.Redirect("/profile/delete?error=deleteprofile")
		}
		return
	}
	if w.Admin {
		if profile.UserID == "" {
			w.Redirect("/?success=deleteprofile")
		} else {
			w.Redirect("/user/edit/%s?success=deleteprofile", profile.UserID)
		}
		return
	}
	w.Redirect("/?success=deleteprofile")
}

func indexHandler(w *Web) {
	if w.User.ID != "" {
		w.TargetProfiles = config.ListProfilesByUser(w.User.ID)
	}
	if w.Admin {
		w.Profiles = config.ListProfilesByUser("")
		w.Users = config.ListUsers()
	} else {
		w.Profiles = config.ListProfilesByUser(w.User.ID)
	}
	w.HTML()
}

func settingsHandler(w *Web) {
	if !w.Admin {
		Error(w.w, fmt.Errorf("settings: permission denied"))
		return
	}

	if w.r.Method == "GET" {
		w.HTML()
		return
	}

	email := strings.ToLower(strings.TrimSpace(w.r.FormValue("email")))
	samlMetadata := strings.TrimSpace(w.r.FormValue("saml_metadata"))

	currentPassword := w.r.FormValue("current_password")
	newPassword := w.r.FormValue("new_password")

	resetTotp := w.r.FormValue("reset_totp")
	totpCode := w.r.FormValue("totp_code")

	config.UpdateInfo(func(i *Info) error {
		i.SAML.IDPMetadata = samlMetadata
		i.Email = email
		return nil
	})

	// Configure SAML if metadata is present.
	if len(samlMetadata) > 0 {
		if err := configureSAML(); err != nil {
			logger.Warnf("configuring SAML failed: %s", err)
			w.Redirect("/settings?error=saml")
		}
	} else {
		samlSP = nil
	}

	if currentPassword != "" || newPassword != "" {
		if !validPassword.MatchString(newPassword) {
			w.Redirect("/settings?error=invalid")
			return
		}

		if err := bcrypt.CompareHashAndPassword(config.FindInfo().Password, []byte(currentPassword)); err != nil {
			w.Redirect("/settings?error=invalid")
			return
		}

		hashedPassword, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
		if err != nil {
			w.Redirect("/settings?error=bcrypt")
			return
		}

		config.UpdateInfo(func(i *Info) error {
			i.Password = hashedPassword
			return nil
		})
	}

	if resetTotp == "true" {
		err := config.ResetTotp()
		if err != nil {
			w.Redirect("/settings?error=totp")
			return
		}

		w.Redirect("/settings?success=totp")
		return
	}

	if config.Info.TotpKey == "" && totpCode != "" {
		if !totp.Validate(totpCode, tempTotpKey.Secret()) {
			w.Redirect("/settings?error=totp")
			return
		}
		config.Info.TotpKey = tempTotpKey.Secret()
		config.save()
	}

	w.Redirect("/settings?success=settings")
}

func helpHandler(w *Web) {
	w.HTML()
}

//
// Helpers
//
func deleteProfile(profile Profile) error {
	script := `
		cd {{$.Datadir}}/wireguard

		wg-bond rm {{$.Profile.ID}}

		# Syncing configuration
		wg-bond conf subspace-root > subspace.conf
		wg-quick strip ./subspace.conf > sync.conf
		wg-quick down ./subspace.conf
		wg-quick up ./subspace.conf
	`

	output, err := bash(script, struct {
		Datadir string
		Profile Profile
	}{
		datadir,
		profile,
	})
	if err != nil {
		return fmt.Errorf("delete profile failed %s %s", err, output)
	}
	return config.DeleteProfile(profile.ID)
}
