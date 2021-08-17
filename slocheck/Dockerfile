FROM python:3.9
RUN pip install google-cloud-monitoring==2.4.0
COPY getslo.py /usr/local/bin/
RUN chmod +x /usr/local/bin/getslo.py
ENTRYPOINT ["/usr/local/bin/getslo.py"]
