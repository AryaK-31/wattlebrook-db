"""Generate the Wattlebrook University synthetic workbook.

Every person, ID, email, phone, tax file number and bank account in the
output is invented. The generator is seeded, so running it again produces the
identical workbook.

Design goals (each one feeds a later pipeline step):
  * Source systems never share an identifier. HRMS, SIS and ADV_CRM each have
    their own key and no master ID, which is the "Priya exists three times"
    problem the identity-resolution step has to solve.
  * The same person looks slightly different in each system: different email
    addresses, phone formats, nicknames, stray spaces/capitals and the odd
    day/month swap in a date of birth. Some overlaps are therefore hard or
    impossible to match, so match accuracy is a real measurement.
  * A few "false friends": different people who share a name and date of
    birth, so the name+DOB rule can be shown to make mistakes.
  * Dates are life-consistent (staff are adults when hired, students enrol at
    17+, alumni graduate after enrolling), except for a small, documented set
    of seeded data-quality test cases.
  * Shadow copies: 27,500 copied records spread over eight uncontrolled
    developer environments between 2012 and 2026, most of them unmasked and
    past their retention expiry date.
  * The true person for every source record is written to a separate
    Identity_Answer_Key sheet, used only to score the matcher.

Usage:
    python python/generate_synthetic_data.py [output.xlsx]
"""

import random
import sys
from datetime import date, timedelta
from pathlib import Path

import pandas as pd

SEED = 2026
AS_OF = date(2026, 10, 12)  # reference "today" for the scenario

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = PROJECT_ROOT / "data" / "Wattlebrook_Synthetic_Data.xlsx"

# Membership counts. Record totals: SIS 15,000, HRMS 5,000, ADV_CRM 7,500.
MEMBERSHIP = {
    ("HRMS", "SIS", "CRM"): 700,
    ("HRMS", "SIS"): 1300,
    ("SIS", "CRM"): 4000,
    ("HRMS", "CRM"): 600,
    ("SIS",): 9000,
    ("HRMS",): 2400,
    ("CRM",): 2200,
}

SHADOW_ROWS = 27_500
FALSE_FRIEND_PAIRS = 15

FIRST_NAMES = [
    "Aaliyah", "Aarav", "Abigail", "Adam", "Aditi", "Ahmed", "Aiden", "Aisha", "Alexander", "Alice",
    "Amelia", "Amir", "Ananya", "Andrew", "Angus", "Anh", "Anthony", "Archie", "Arjun", "Ava",
    "Benjamin", "Bella", "Bilal", "Bridget", "Caleb", "Charlotte", "Chen", "Chloe", "Christopher", "Claire",
    "Daniel", "David", "Deepa", "Dylan", "Eleanor", "Elijah", "Elizabeth", "Ella", "Emily", "Emma",
    "Ethan", "Fatima", "Finn", "Florence", "Gabriel", "Georgia", "Grace", "Hamish", "Hannah", "Harper",
    "Harrison", "Harvey", "Hiroshi", "Hugo", "Ibrahim", "Isaac", "Isabella", "Isla", "Ivy", "Jack",
    "Jacob", "James", "Jasmine", "Jessica", "Ji-woo", "Joshua", "Kai", "Karan", "Katherine", "Kiara",
    "Layla", "Leo", "Liam", "Lily", "Lucas", "Lucy", "Mai", "Matilda", "Matthew", "Maya",
    "Mia", "Michael", "Mihir", "Min-jun", "Mohammed", "Nathan", "Neha", "Nicholas", "Noah", "Oliver",
    "Olivia", "Omar", "Oscar", "Priya", "Rahul", "Rebecca", "Riya", "Rosa", "Ruby", "Ryan",
    "Samuel", "Sarah", "Sebastian", "Sienna", "Sofia", "Sophie", "Thomas", "Tran", "Victoria", "William",
    "Xavier", "Yara", "Yusuf", "Zara", "Zoe", "Margaret", "Robert", "Patricia", "Jennifer", "Susan",
]

NICKNAMES = {
    "Alexander": "Alex", "Benjamin": "Ben", "Christopher": "Chris", "Daniel": "Dan", "Elizabeth": "Liz",
    "Isabella": "Bella", "Jacob": "Jake", "James": "Jim", "Katherine": "Kate", "Matthew": "Matt",
    "Michael": "Mike", "Nicholas": "Nick", "Rebecca": "Becky", "Robert": "Bob", "Samuel": "Sam",
    "Thomas": "Tom", "Victoria": "Tori", "William": "Will", "Margaret": "Maggie", "Patricia": "Trish",
    "Jennifer": "Jen", "Joshua": "Josh", "Sebastian": "Seb", "Andrew": "Andy", "Anthony": "Tony",
}

LAST_NAMES = [
    "Ali", "Anderson", "Bailey", "Baker", "Banerjee", "Brown", "Campbell", "Chan", "Chauhan", "Chen",
    "Clarke", "Cooper", "Davies", "Desai", "Do", "Edwards", "Evans", "Fernando", "Fraser", "Garcia",
    "Ghosh", "Gupta", "Hall", "Harris", "Ho", "Huang", "Hughes", "Hussain", "Iyer", "Jackson",
    "Johnson", "Jones", "Joshi", "Kaur", "Kelly", "Khan", "Kim", "King", "Kumar", "Lam",
    "Le", "Lee", "Lewis", "Li", "Lin", "Liu", "Martin", "Mehta", "Miller", "Mitchell",
    "Moore", "Morris", "Murphy", "Nair", "Nguyen", "O'Brien", "Park", "Patel", "Pham", "Phillips",
    "Rao", "Reddy", "Roberts", "Robinson", "Rossi", "Ryan", "Saito", "Shah", "Sharma", "Singh",
    "Smith", "Stewart", "Sullivan", "Tan", "Taylor", "Thomas", "Thompson", "Tran", "Turner", "Vo",
    "Walker", "Wang", "Watson", "White", "Williams", "Wilson", "Wong", "Wright", "Wu", "Xu",
    "Yamamoto", "Yang", "Young", "Zhang", "Zhao", "Kowalski", "Papadopoulos", "Haddad", "Okafor", "Mensah",
]

SUBURBS = [  # (suburb, postcode) in the Sydney region
    ("Ultimo", "2007"), ("Glebe", "2037"), ("Newtown", "2042"), ("Parramatta", "2150"), ("Strathfield", "2135"),
    ("Burwood", "2134"), ("Chatswood", "2067"), ("Hornsby", "2077"), ("Mascot", "2020"), ("Randwick", "2031"),
    ("Kensington", "2033"), ("Bondi", "2026"), ("Liverpool", "2170"), ("Blacktown", "2148"), ("Penrith", "2750"),
    ("Hurstville", "2220"), ("Epping", "2121"), ("Ryde", "2112"), ("Marrickville", "2204"), ("Ashfield", "2131"),
    ("Auburn", "2144"), ("Campsie", "2194"), ("Rhodes", "2138"), ("Wollongong", "2500"), ("Manly", "2095"),
]
STREETS = ["George St", "Harris St", "King St", "Church St", "Victoria Rd", "Pitt St", "Park Rd", "Railway Pde",
           "Station St", "High St", "Elizabeth St", "Oxford St", "Anzac Pde", "Pacific Hwy", "Military Rd"]
EMAIL_DOMAINS = ["example.com", "example.net", "example.org", "mail.example.com"]

DEPARTMENTS = ["Engineering & IT", "Business School", "Health", "Science", "Law", "Arts & Social Sciences",
               "Library", "Student Services", "Finance Office", "Facilities", "Research Office", "Design"]
PROGRAMS = [("BENG", "Bachelor of Engineering", "Undergraduate"), ("BCOM", "Bachelor of Commerce", "Undergraduate"),
            ("BSC", "Bachelor of Science", "Undergraduate"), ("BIT", "Bachelor of Information Technology", "Undergraduate"),
            ("BNUR", "Bachelor of Nursing", "Undergraduate"), ("LLB", "Bachelor of Laws", "Undergraduate"),
            ("BA", "Bachelor of Arts", "Undergraduate"), ("MIT", "Master of Information Technology", "Postgraduate"),
            ("MBA", "Master of Business Administration", "Postgraduate"), ("MDS", "Master of Data Science", "Postgraduate"),
            ("MPH", "Master of Public Health", "Postgraduate"), ("PHD", "Doctor of Philosophy", "Research")]
ENVIRONMENTS = [
    ("sandbox_dev_team_a", "Developer sandbox, team A"),
    ("sandbox_test_team_b", "Test sandbox, team B"),
    ("git_repo_legacy_admissions", "Fixture files in the legacy admissions repo"),
    ("git_repo_hr_migration", "CSV extracts committed to the HR migration repo"),
    ("git_repo_alumni_portal", "Seed data in the alumni portal repo"),
    ("staging_crm_integration", "CRM integration staging database"),
    ("shared_test_drive", "Spreadsheets on the shared test drive"),
    ("developer_laptop_export", "Exports recovered from developer laptops"),
]
PURPOSES = [("bug_reproduction", 90), ("feature_testing", 180), ("integration_testing", 365),
            ("performance_testing", 180), ("migration_testing", 730)]  # (purpose, approved retention days)


def rand_date(rng, start, end):
    return start + timedelta(days=rng.randint(0, (end - start).days))


def mobile(rng):
    # 04xx xxx xxx, avoiding 0491 57x xxx (ACMA's reserved fictitious range, used by the masking step)
    while True:
        digits = "04" + "".join(str(rng.randint(0, 9)) for _ in range(8))
        if not digits.startswith("049157"):
            return digits


def fmt_phone(digits, style):
    if style == "spaced":
        return f"{digits[:4]} {digits[4:7]} {digits[7:]}"
    if style == "intl":
        return f"+61 {digits[1:4]} {digits[4:7]} {digits[7:]}"
    return digits


def noisy(rng, value, p=0.08):
    """Return value with stray whitespace or changed capitals, with probability p."""
    if rng.random() >= p:
        return value
    choice = rng.randint(0, 2)
    if choice == 0:
        return value.upper()
    if choice == 1:
        return value.lower()
    return f" {value}  "


def slug(text):
    return "".join(ch for ch in text.lower() if ch.isalnum())


class Generator:
    def __init__(self, seed=SEED):
        self.rng = random.Random(seed)
        self.people = []
        self.hrms, self.sis, self.crm, self.answer_key, self.shadow = [], [], [], [], []
        self.dq_cases = []

    # ------------------------------------------------------------------ people
    def make_people(self):
        rng = self.rng
        pid = 0
        for systems, count in MEMBERSHIP.items():
            for _ in range(count):
                pid += 1
                first, last = rng.choice(FIRST_NAMES), rng.choice(LAST_NAMES)
                suburb, postcode = rng.choice(SUBURBS)
                self.people.append({
                    "true_person_id": f"TP{pid:06d}",
                    "systems": set(systems),
                    "first_name": first,
                    "last_name": last,
                    "personal_email": f"{slug(first)}.{slug(last)}{rng.randint(1, 9999)}@{rng.choice(EMAIL_DOMAINS)}",
                    "mobile": mobile(rng),
                    "address": f"{rng.randint(1, 250)} {rng.choice(STREETS)}",
                    "suburb": suburb,
                    "postcode": postcode,
                    "international": rng.random() < 0.28,
                })
        self._plan_life_dates()
        self._add_false_friends()

    def _plan_life_dates(self):
        """Choose dates of birth and role dates that are consistent with each other."""
        rng = self.rng
        for p in self.people:
            s = p["systems"]
            # Earliest/latest birth years that keep every role plausible.
            if "SIS" in s and "CRM" in s:          # studied here, now alumni: graduated 2008-2025
                birth_lo, birth_hi = 1968, 2004
            elif "SIS" in s:                        # any student, 2008-2026 intake
                birth_lo, birth_hi = 1966, 2009
            elif "HRMS" in s:
                birth_lo, birth_hi = 1958, 2002
            else:                                   # CRM-only: alumni from other eras, donors
                birth_lo, birth_hi = 1945, 2000
            if "HRMS" in s:
                birth_hi = min(birth_hi, 2002)
            p["dob"] = rand_date(rng, date(birth_lo, 1, 1), date(birth_hi, 12, 31))
            by = p["dob"].year

            if "SIS" in s:
                if "CRM" in s:
                    enrol = rng.randint(max(2008, by + 17), min(2021, by + 40))
                else:
                    enrol = rng.randint(max(2008, by + 17), min(2026, by + 45))
                p["program"] = rng.choice(PROGRAMS)
                length = {"Undergraduate": 3, "Postgraduate": 2, "Research": 4}[p["program"][2]] + rng.randint(0, 1)
                p["enrolment_year"] = enrol
                if "CRM" in s:
                    status = "Completed"
                elif enrol + length > 2026:
                    status = rng.choices(["Enrolled", "Deferred", "Withdrawn"], [85, 8, 7])[0]
                else:
                    status = rng.choices(["Completed", "Withdrawn", "Enrolled"], [80, 15, 5])[0]
                p["enrolment_status"] = status
                if status == "Completed":
                    p["completion_year"] = min(enrol + length, 2025)
                    p["last_activity"] = date(p["completion_year"], 12, rng.randint(1, 18))
                elif status == "Withdrawn":
                    p["completion_year"] = None
                    p["last_activity"] = rand_date(rng, date(enrol, 3, 1), date(min(enrol + 2, 2026), 6, 30))
                    p["last_activity"] = min(p["last_activity"], AS_OF - timedelta(days=30))
                else:
                    p["completion_year"] = None
                    p["last_activity"] = rand_date(rng, date(2026, 2, 1), date(2026, 9, 30))

            if "HRMS" in s:
                earliest = max(date(1995, 1, 1), date(by + 21, p["dob"].month, min(p["dob"].day, 28)))
                start = rand_date(rng, earliest, date(2026, 8, 31))
                p["employment_start"] = start
                if rng.random() < 0.42 and start < date(2025, 6, 1):
                    p["employment_status"] = "Former"
                    p["employment_end"] = rand_date(rng, start + timedelta(days=200), date(2026, 6, 30))
                else:
                    p["employment_status"] = "Current"
                    p["employment_end"] = None

            if "CRM" in s:
                if "SIS" in s:
                    p["alumni_year"] = p["completion_year"]
                    p["contact_type"] = "Alumni & Donor" if rng.random() < 0.18 else "Alumni"
                elif "HRMS" in s:
                    p["alumni_year"] = None
                    p["contact_type"] = "Donor"
                else:
                    p["alumni_year"] = rng.randint(max(1975, by + 21), min(2025, by + 50))
                    p["contact_type"] = rng.choices(["Alumni", "Alumni & Donor", "Donor"], [70, 20, 10])[0]
                    if p["contact_type"] == "Donor":
                        p["alumni_year"] = None
                floor = date(max(2005, (p["alumni_year"] or 2005)), 1, 1)
                p["last_contact"] = rand_date(rng, floor, date(2026, 9, 30))

    def _add_false_friends(self):
        """Make pairs of *different* people share name + date of birth across systems."""
        rng = self.rng
        sis_only = [p for p in self.people if p["systems"] == {"SIS"} and p["enrolment_status"] == "Enrolled"]
        crm_only = [p for p in self.people if p["systems"] == {"CRM"}]
        hr_only = [p for p in self.people if p["systems"] == {"HRMS"}]
        for i in range(FALSE_FRIEND_PAIRS):
            a = rng.choice(sis_only)
            b = rng.choice(crm_only if i % 2 == 0 else hr_only)
            b["first_name"], b["last_name"] = a["first_name"], a["last_name"]
            # keep b's role dates valid: only copy the DOB if it still fits b's role
            if b["systems"] == {"CRM"} and (b["alumni_year"] is None or b["alumni_year"] >= a["dob"].year + 21):
                b["dob"] = a["dob"]
            elif b["systems"] == {"HRMS"} and b["employment_start"].year >= a["dob"].year + 21:
                b["dob"] = a["dob"]
            else:
                a["dob"] = b["dob"] if a["enrolment_year"] >= b["dob"].year + 17 else a["dob"]
                if a["dob"] != b["dob"]:
                    continue
            b["false_friend_of"] = a["true_person_id"]

    # ------------------------------------------------------------ source rows
    def _variant(self, p, system):
        """How this person appears in one system: name, email, phone and DOB variants."""
        rng = self.rng
        first, last, dob = p["first_name"], p["last_name"], p["dob"]
        multi = len(p["systems"]) > 1
        if multi and system != "SIS" and first in NICKNAMES and rng.random() < 0.25:
            first = NICKNAMES[first]
        if multi and system == "CRM" and rng.random() < 0.03 and len(last) > 3:   # surname typo
            i = rng.randint(1, len(last) - 2)
            last = last[:i] + last[i + 1] + last[i] + last[i + 2:]
        if multi and rng.random() < 0.02 and dob.day <= 12 and dob.day != dob.month:  # day/month swapped
            dob = date(dob.year, dob.day, dob.month)
        phone = p["mobile"] if rng.random() > 0.2 else mobile(rng)  # 20% hold an old number
        return noisy(rng, first), noisy(rng, last), dob, phone

    def make_sources(self):
        rng = self.rng
        n_hr = n_sis = n_crm = 0
        for p in self.people:
            s = p["systems"]
            if "SIS" in s:
                n_sis += 1
                first, last, dob, phone = self._variant(p, "SIS")
                use_personal = rng.random() < 0.4
                email = p["personal_email"] if use_personal else \
                    f"{slug(p['first_name'])}.{slug(p['last_name'])}{n_sis}@student.wattlebrook.edu.au"
                code, name, level = p["program"]
                sid = f"STU{n_sis:07d}"
                self.sis.append({
                    "sis_student_id": sid, "first_name": first, "last_name": last,
                    "date_of_birth": dob.isoformat(), "email": noisy(rng, email, 0.05),
                    "phone": fmt_phone(phone, "plain"), "home_address": p["address"],
                    "suburb": p["suburb"], "postcode": p["postcode"],
                    "program_code": code, "program_name": name, "study_level": level,
                    "enrolment_status": p["enrolment_status"], "enrolment_year": p["enrolment_year"],
                    "completion_year": p["completion_year"],
                    "international_flag": "Y" if p["international"] else "N",
                    "visa_status": rng.choice(["Student (500)", "Graduate (485)"]) if p["international"] else "Citizen/PR",
                    "gpa": round(rng.uniform(3.2, 7.0), 2),
                    "outstanding_fees_aud": round(rng.choice([0, 0, 0, rng.uniform(50, 18000)]), 2),
                    "last_activity_date": p["last_activity"].isoformat(),
                })
                self.answer_key.append(("SIS", sid, p["true_person_id"]))
            if "HRMS" in s:
                n_hr += 1
                first, last, dob, phone = self._variant(p, "HRMS")
                email = p["personal_email"] if rng.random() < 0.3 else \
                    f"{slug(p['first_name'])[0]}.{slug(p['last_name'])}{n_hr}@staff.wattlebrook.edu.au"
                eid = f"EMP{n_hr:06d}"
                self.hrms.append({
                    "hr_employee_id": eid, "first_name": first, "last_name": last,
                    "date_of_birth": dob.isoformat(), "email": noisy(rng, email, 0.05),
                    "phone": fmt_phone(phone, "spaced"), "home_address": p["address"],
                    "suburb": p["suburb"], "postcode": p["postcode"],
                    "tax_file_number": f"{rng.randint(100, 999)} {rng.randint(100, 999)} {rng.randint(100, 999)}",
                    "bank_bsb": f"{rng.choice(['062', '032', '082', '012'])}-{rng.randint(0, 999):03d}",
                    "bank_account": f"{rng.randint(10000000, 99999999)}",
                    "department": rng.choice(DEPARTMENTS),
                    "position_title": rng.choice(["Lecturer", "Senior Lecturer", "Professor", "Research Fellow",
                                                  "Administrator", "Librarian", "Technician", "Analyst", "Manager"]),
                    "salary_band": f"B{rng.randint(2, 10)}",
                    "employment_status": p["employment_status"],
                    "employment_start_date": p["employment_start"].isoformat(),
                    "employment_end_date": p["employment_end"].isoformat() if p["employment_end"] else None,
                })
                self.answer_key.append(("HRMS", eid, p["true_person_id"]))
            if "CRM" in s:
                n_crm += 1
                first, last, dob, phone = self._variant(p, "CRM")
                cid = f"CRM{n_crm:07d}"
                donor = "Donor" in p["contact_type"]
                self.crm.append({
                    "crm_contact_id": cid, "first_name": first, "last_name": last,
                    "date_of_birth": dob.isoformat(), "email": noisy(rng, p["personal_email"], 0.05),
                    "phone": fmt_phone(phone, "intl"), "home_address": p["address"],
                    "suburb": p["suburb"], "postcode": p["postcode"],
                    "contact_type": p["contact_type"], "alumni_year": p["alumni_year"],
                    "employer": rng.choice(["Atlassian", "Westpac", "NSW Health", "Canva", "Deloitte", "Self-employed",
                                            "Telstra", "CSIRO", "Commonwealth Bank", "Not recorded"]),
                    "donor_flag": "Y" if donor else "N",
                    "lifetime_donation_aud": round(rng.uniform(25, 25000), 2) if donor else 0.0,
                    "engagement_score": rng.randint(0, 100),
                    "last_contact_date": p["last_contact"].isoformat(),
                })
                self.answer_key.append(("ADV_CRM", cid, p["true_person_id"]))
        self._seed_dq_cases()

    def _seed_dq_cases(self):
        """A handful of deliberately impossible rows, so the data-quality checks have something to catch."""
        rng = self.rng
        for row in rng.sample(self.hrms, 4):   # hired before age 15
            dob = date.fromisoformat(row["date_of_birth"])
            row["employment_start_date"] = date(dob.year + rng.randint(3, 12), 2, 1).isoformat()
            if row["employment_end_date"] and row["employment_end_date"] < row["employment_start_date"]:
                row["employment_end_date"] = None
                row["employment_status"] = "Current"
            self.dq_cases.append(("HRMS", row["hr_employee_id"], "employment_start_date before age 15"))
        for row in rng.sample(self.sis, 4):    # date of birth in the future
            row["date_of_birth"] = date(2027, rng.randint(1, 12), rng.randint(1, 28)).isoformat()
            self.dq_cases.append(("SIS", row["sis_student_id"], "date_of_birth in the future"))
        for row in rng.sample([r for r in self.crm if r["alumni_year"]], 4):  # graduated before age 15
            dob = date.fromisoformat(row["date_of_birth"])
            row["alumni_year"] = dob.year + rng.randint(2, 10)
            self.dq_cases.append(("ADV_CRM", row["crm_contact_id"], "alumni_year before age 15"))

    # ------------------------------------------------------------ shadow copies
    def make_shadow(self):
        """27,500 copied records, one per source record, scattered over eight environments."""
        rng = self.rng
        sources = [("SIS", r, r["sis_student_id"]) for r in self.sis] + \
                  [("HRMS", r, r["hr_employee_id"]) for r in self.hrms] + \
                  [("ADV_CRM", r, r["crm_contact_id"]) for r in self.crm]
        rng.shuffle(sources)
        sources = sources[:SHADOW_ROWS]
        env_bias = {"SIS": ["sandbox_dev_team_a", "sandbox_test_team_b", "git_repo_legacy_admissions",
                            "shared_test_drive", "developer_laptop_export"],
                    "HRMS": ["git_repo_hr_migration", "sandbox_dev_team_a", "shared_test_drive", "developer_laptop_export"],
                    "ADV_CRM": ["git_repo_alumni_portal", "staging_crm_integration", "sandbox_test_team_b",
                                "shared_test_drive"]}
        for n, (system, rec, rec_id) in enumerate(sources, start=1):
            env = rng.choice(env_bias[system])
            purpose, keep_days = rng.choice(PURPOSES)
            # Most copies are old; a few are recent so not everything is expired.
            # The HR migration repo was abandoned in 2016: every copy in it is long expired.
            if env == "git_repo_hr_migration":
                extracted = rand_date(rng, date(2014, 1, 1), date(2016, 6, 30))
            elif rng.random() < 0.06:
                extracted = rand_date(rng, AS_OF - timedelta(days=keep_days - 1), AS_OF - timedelta(days=1))
            else:
                extracted = rand_date(rng, date(2012, 1, 1), date(2025, 12, 31))
            expiry = extracted + timedelta(days=keep_days)
            masked = rng.random() < 0.06
            last_access = rand_date(rng, extracted, min(AS_OF, extracted + timedelta(days=rng.randint(10, 1500))))
            sensitive = {"SIS": rec.get("visa_status"), "HRMS": rec.get("tax_file_number"),
                         "ADV_CRM": f"{rec.get('lifetime_donation_aud')}"}[system]
            row = {
                "shadow_record_id": f"SHD{n:06d}", "environment": env, "source_system": system,
                "source_record_id": rec_id, "extracted_date": extracted.isoformat(),
                "purpose": purpose, "approved_retention_days": keep_days,
                "retention_expiry_date": expiry.isoformat(),
                "pii_classification": "Highly Restricted" if system == "HRMS" or rng.random() < 0.3 else "Restricted",
                "masked": "Yes" if masked else "No",
                "catalogued": "Yes" if rng.random() < 0.04 else "No",
                "lineage_tracked": "Yes" if rng.random() < 0.03 else "No",
                "access_group": rng.choice(["developers", "testers", "data_engineers", "contractors", "legacy_team"]),
                "last_accessed_date": last_access.isoformat(),
                # The copied personal data itself, as it was at extraction time.
                "first_name": "XXXX" if masked else rec["first_name"],
                "last_name": "XXXX" if masked else rec["last_name"],
                "email": "masked@example.invalid" if masked else rec["email"],
                "date_of_birth": None if masked else rec["date_of_birth"],
                "phone": None if masked else rec["phone"],
                "home_address": None if masked else rec["home_address"],
                "sensitive_value": None if masked else sensitive,
            }
            self.shadow.append(row)

    # ------------------------------------------------------------------ output
    def data_dictionary(self):
        rows = [
            ("HRMS", "hr_employee_id", "HR system key (EMPnnnnnn)", "Business key for hub_employee"),
            ("HRMS", "tax_file_number / bank_bsb / bank_account", "Synthetic financial identifiers", "FINANCIAL PII, masked in test_masked"),
            ("HRMS", "employment_end_date", "Set for former staff", "Drives retention policy RP-02"),
            ("SIS", "sis_student_id", "Student system key (STUnnnnnnn)", "Business key for hub_student"),
            ("SIS", "visa_status / outstanding_fees_aud / gpa", "Sensitive student attributes", "SENSITIVE PII"),
            ("SIS", "last_activity_date", "Completion, withdrawal or latest enrolment activity", "Drives retention policy RP-01"),
            ("ADV_CRM", "crm_contact_id", "Advancement CRM key (CRMnnnnnnn)", "Business key for hub_constituent"),
            ("ADV_CRM", "last_contact_date", "Most recent engagement with the contact", "Drives retention policy RP-03"),
            ("All sources", "first_name, last_name, date_of_birth, email, phone, home_address", "Person attributes; formats differ by system",
             "Inputs to identity resolution (rules R1-R3)"),
            ("Shadow_Extracts", "environment", "Uncontrolled copy location; each becomes a dev_sandbox table", "Discovery scan and catalogue"),
            ("Shadow_Extracts", "retention_expiry_date", "extracted_date + approved_retention_days", "Drives retention policy RP-04"),
            ("Shadow_Extracts", "masked / catalogued / lineage_tracked", "Governance state at the time of the 2026 audit", "Baseline (before) report"),
            ("Identity_Answer_Key", "true_person_id", "Which real person each source record belongs to", "QA only: scores the matcher, never loaded into sources"),
            ("DQ_Test_Cases", "issue", "Rows deliberately made impossible", "Expected findings of the data-quality checks"),
        ]
        return pd.DataFrame(rows, columns=["sheet", "column", "meaning", "use_in_pipeline"])

    def build(self):
        self.make_people()
        self.make_sources()
        self.make_shadow()
        key = pd.DataFrame(self.answer_key, columns=["source_system", "source_record_id", "true_person_id"])
        ff = {p["true_person_id"]: p.get("false_friend_of") for p in self.people if p.get("false_friend_of")}
        key["false_friend_of"] = key["true_person_id"].map(ff)
        return {
            "HRMS": pd.DataFrame(self.hrms),
            "SIS": pd.DataFrame(self.sis),
            "ADV_CRM": pd.DataFrame(self.crm),
            "Shadow_Extracts": pd.DataFrame(self.shadow),
            "Identity_Answer_Key": key,
            "DQ_Test_Cases": pd.DataFrame(self.dq_cases, columns=["source_system", "source_record_id", "issue"]),
            "Data_Dictionary": self.data_dictionary(),
        }


def main(out_path=DEFAULT_OUT):
    sheets = Generator().build()
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with pd.ExcelWriter(out_path, engine="openpyxl") as xw:
        for name, df in sheets.items():
            df.to_excel(xw, sheet_name=name, index=False)
    for name, df in sheets.items():
        print(f"{name:20s} {len(df):>6,} rows")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT)
