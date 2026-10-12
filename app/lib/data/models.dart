/// نماذج البيانات الأساسية (تُطابق جداول قاعدة البيانات).
library;

class School {
  final String id;
  final String name;
  final String timezone;
  School({required this.id, required this.name, this.timezone = 'Asia/Baghdad'});

  factory School.fromMap(Map<String, dynamic> m) =>
      School(id: m['id'], name: m['name'], timezone: m['timezone'] ?? 'Asia/Baghdad');
}

class Student {
  final String id;
  final String schoolId;
  final String studentNumber;
  final String fullName;
  final String? gender;
  final String? birthDate;
  final String? address;
  final String? sectionId;
  final String? academicYearId;
  final String status;
  final String? photoPath;
  final String? notes;
  final String? nationalId;
  final String? studentPhone;
  final String? guardianName;
  final String? guardianPhone;
  final String? residence;
  final String? enrollmentDate;

  Student({
    required this.id,
    required this.schoolId,
    required this.studentNumber,
    required this.fullName,
    this.gender,
    this.birthDate,
    this.address,
    this.sectionId,
    this.academicYearId,
    this.status = 'active',
    this.photoPath,
    this.notes,
    this.nationalId,
    this.studentPhone,
    this.guardianName,
    this.guardianPhone,
    this.residence,
    this.enrollmentDate,
  });

  factory Student.fromMap(Map<String, dynamic> m) => Student(
        id: m['id'],
        schoolId: m['school_id'],
        studentNumber: m['student_number'],
        fullName: m['full_name'],
        gender: m['gender'],
        birthDate: m['birth_date'],
        address: m['address'],
        sectionId: m['section_id'],
        academicYearId: m['academic_year_id'],
        status: m['status'] ?? 'active',
        photoPath: m['photo_path'],
        notes: m['notes'],
        nationalId: m['national_id'],
        studentPhone: m['student_phone'],
        guardianName: m['guardian_name'],
        guardianPhone: m['guardian_phone'],
        residence: m['residence'],
        enrollmentDate: m['enrollment_date'],
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'school_id': schoolId,
        'student_number': studentNumber,
        'full_name': fullName,
        'gender': gender,
        'birth_date': birthDate,
        'address': address,
        'section_id': sectionId,
        'academic_year_id': academicYearId,
        'status': status,
        'photo_path': photoPath,
        'notes': notes,
        'national_id': nationalId,
        'student_phone': studentPhone,
        'guardian_name': guardianName,
        'guardian_phone': guardianPhone,
        'residence': residence,
        'enrollment_date': enrollmentDate,
      };
}

class AttendanceRecord {
  final String id;
  final String studentId;
  final String sessionDate;
  final String sessionType;
  final String status; // present|late|absent|excused|early_leave
  final String recordedAt;
  final String timeSource; // server|device
  final String source; // face|manual|api
  final String? deviceId;
  final String clientUuid;
  final double? confidence;

  AttendanceRecord({
    required this.id,
    required this.studentId,
    required this.sessionDate,
    this.sessionType = 'morning',
    required this.status,
    required this.recordedAt,
    this.timeSource = 'device',
    this.source = 'face',
    this.deviceId,
    required this.clientUuid,
    this.confidence,
  });

  factory AttendanceRecord.fromMap(Map<String, dynamic> m) => AttendanceRecord(
        id: m['id'],
        studentId: m['student_id'],
        sessionDate: m['session_date'],
        sessionType: m['session_type'] ?? 'morning',
        status: m['status'],
        recordedAt: m['recorded_at'],
        timeSource: m['time_source'] ?? 'device',
        source: m['source'] ?? 'face',
        deviceId: m['device_id'],
        clientUuid: m['client_uuid'],
        confidence: (m['confidence'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'student_id': studentId,
        'session_date': sessionDate,
        'session_type': sessionType,
        'status': status,
        'recorded_at': recordedAt,
        'time_source': timeSource,
        'source': source,
        'device_id': deviceId,
        'client_uuid': clientUuid,
        'confidence': confidence,
      };
}

class BiometricTemplate {
  final String id;
  final String studentId;
  final List<int> templateEncrypted;
  final int embeddingDim;
  final String templateVersion;
  final double? qualityScore;
  final bool isActive;

  BiometricTemplate({
    required this.id,
    required this.studentId,
    required this.templateEncrypted,
    this.embeddingDim = 128,
    this.templateVersion = 'mobilefacenet-v1',
    this.qualityScore,
    this.isActive = true,
  });
}

class FaceMatch {
  final String? studentId;
  final double score;
  final double secondScore;
  final bool accepted;
  final String result; // matched|no_match|ambiguous|low_quality|spoof

  FaceMatch({
    this.studentId,
    required this.score,
    this.secondScore = 0,
    required this.accepted,
    required this.result,
  });
}
